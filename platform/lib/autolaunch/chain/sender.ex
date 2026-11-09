defmodule Autolaunch.Chain.Sender do
  @moduledoc """
  Sends a call from one of the site's own wallets (`Autolaunch.Chain.Wallet`),
  and settles what it sent. The auction finisher and the After-hours price
  recorder both send this way, each keeping its own record of what it sent
  (a `Autolaunch.Chain.Sender.Ledger`).

  A send reserves the nonce, signs, and commits the signed transaction to the
  ledger before anything is broadcast, so a failure after the broadcast, or a
  worker that dies there, leaves the transaction recorded. Reserving and
  recording hold a database lock for the chain and the wallet, so two
  machines never reserve the same nonce: the nonce is the wallet's pending
  count, or one above the highest the ledger has recorded if that is higher,
  which covers a recorded transaction not yet broadcast.

  An owner (a launch, a series) with a recorded transaction the chain has not
  settled is never sent another. `settle/3` reads the recorded one first: its
  receipt settles it as mined or reverted; one the network holds is waited
  for; one whose nonce the wallet has already used is dropped; and one the
  network never saw is broadcast again, exactly as signed.

  The call is estimated before signing, so a call the chain would refuse costs
  nothing. The fee allows the base fee to rise tenfold before the transaction
  stops being included; only the base fee at inclusion is paid, so a stuck
  transaction, which holds up every later one from its wallet, is rare.
  """

  require Logger

  alias Autolaunch.Chain.{Rpc, Wallet}
  alias Autolaunch.Repo

  defmodule Ledger do
    @moduledoc "Where one sender keeps the transactions it signed."

    @doc "The owner's recorded transaction the chain has not settled, if any."
    @callback unsettled(owner :: struct()) :: {:ok, struct() | nil} | {:error, term()}

    @doc "The wallet's highest recorded transaction on a chain, if any."
    @callback highest_nonce(chain_id :: pos_integer(), signer :: String.t()) ::
                {:ok, struct() | nil} | {:error, term()}

    @doc "Commits a signed transaction for the owner."
    @callback record(owner :: struct(), attrs :: map()) :: {:ok, struct()} | {:error, term()}

    @doc "Settles a recorded transaction as mined, reverted or dropped."
    @callback settle_transaction(
                transaction :: struct(),
                outcome :: :mined | :reverted | :dropped
              ) ::
                {:ok, struct()} | {:error, term()}

    @doc "The sender's name, in its lock and its log lines."
    @callback label() :: String.t()
  end

  @doc """
  Settles the owner's recorded transaction, if it has one: `{:ok, :clear}`
  when there is nothing left unsettled, `{:ok, :waiting}` while there is.
  `chain` is `%{chain_id: id, opts: rpc_opts}`.
  """
  def settle(ledger, chain, owner) do
    case ledger.unsettled(owner) do
      {:ok, nil} -> {:ok, :clear}
      {:ok, transaction} -> reconcile(ledger, chain, transaction)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reserves a nonce, signs and records the call for `owner`, then broadcasts it."
  def send_call(ledger, chain, owner, %Wallet{} = wallet, %{to: to, data: data}) do
    opts = chain.opts

    with {:ok, gas} <-
           quantity("eth_estimateGas", [%{from: wallet.address, to: to, data: data}], opts),
         {:ok, tip} <- quantity("eth_maxPriorityFeePerGas", [], opts),
         {:ok, base_fee} <- base_fee(opts),
         {:ok, transaction} <-
           record(ledger, chain, owner, wallet, %{
             chain_id: chain.chain_id,
             max_priority_fee: tip,
             max_fee: 10 * base_fee + tip,
             gas_limit: gas + div(gas, 5),
             to: to,
             data: data
           }),
         {:ok, _hash} <- broadcast(chain, transaction),
         do: {:ok, transaction}
  end

  # The nonce is read from the chain inside the lock, because the lock is what
  # makes the read and the recorded nonces one decision.
  defp record(ledger, chain, owner, wallet, call) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [
        lock_key(ledger, chain.chain_id, wallet.address)
      ])

      with {:ok, pending} <-
             quantity("eth_getTransactionCount", [wallet.address, "pending"], chain.opts),
           {:ok, recorded} <- highest_recorded(ledger, chain.chain_id, wallet.address),
           nonce = max(pending, recorded + 1),
           {raw, hash} = Wallet.sign(wallet, Map.put(call, :nonce, nonce)),
           {:ok, transaction} <-
             ledger.record(owner, %{
               chain_id: chain.chain_id,
               signer: wallet.address,
               nonce: nonce,
               transaction_hash: hash,
               raw_transaction: raw
             }) do
        transaction
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp highest_recorded(ledger, chain_id, signer) do
    case ledger.highest_nonce(chain_id, signer) do
      {:ok, nil} -> {:ok, -1}
      {:ok, transaction} -> {:ok, transaction.nonce}
      {:error, reason} -> {:error, reason}
    end
  end

  # The wallet's mined count is read at the safe block, before the receipt.
  # Every node answering the receipt has passed that block, so a count past
  # this nonce with no receipt means another transaction used the nonce, never
  # that a node behind the head has not yet seen this one mined.
  defp reconcile(ledger, chain, transaction) do
    opts = chain.opts

    with {:ok, mined} <-
           quantity("eth_getTransactionCount", [transaction.signer, "safe"], opts),
         {:ok, receipt} <-
           Rpc.request("eth_getTransactionReceipt", [transaction.transaction_hash], opts),
         {:ok, seen} <-
           Rpc.request("eth_getTransactionByHash", [transaction.transaction_hash], opts) do
      case {receipt, seen} do
        {%{"status" => "0x1"}, _seen} -> settled(ledger, transaction, :mined)
        {%{"status" => "0x0"}, _seen} -> settled(ledger, transaction, :reverted)
        {nil, %{}} -> {:ok, :waiting}
        {nil, nil} when mined > transaction.nonce -> settled(ledger, transaction, :dropped)
        {nil, nil} -> rebroadcast(ledger, chain, transaction)
        _malformed -> {:error, :invalid_chain_response}
      end
    end
  end

  defp settled(ledger, transaction, outcome) do
    with {:ok, _transaction} <- ledger.settle_transaction(transaction, outcome),
         do: {:ok, :clear}
  end

  # The network may refuse the bytes as already known or as too late; the next
  # settle reads which it was, so a refusal here is only reported.
  defp rebroadcast(ledger, chain, transaction) do
    case broadcast(chain, transaction) do
      {:ok, _hash} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "#{ledger.label()} could not rebroadcast #{transaction.transaction_hash}: #{inspect(reason)}"
        )
    end

    {:ok, :waiting}
  end

  defp broadcast(chain, transaction),
    do: Rpc.request("eth_sendRawTransaction", [transaction.raw_transaction], chain.opts)

  defp lock_key(ledger, chain_id, signer) do
    <<key::signed-64, _rest::binary>> =
      :crypto.hash(:sha256, "#{ledger.label()} #{chain_id} #{String.downcase(signer)}")

    key
  end

  defp base_fee(opts) do
    case Rpc.request("eth_getBlockByNumber", ["latest", false], opts) do
      {:ok, %{"baseFeePerGas" => base_fee}} -> parse(base_fee)
      {:ok, _header} -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp quantity(method, params, opts) do
    with {:ok, value} <- Rpc.request(method, params, opts), do: parse(value)
  end

  defp parse("0x" <> hex) when hex != "" do
    case Integer.parse(hex, 16) do
      {value, ""} -> {:ok, value}
      _malformed -> {:error, :invalid_chain_response}
    end
  end

  defp parse(_value), do: {:error, :invalid_chain_response}
end
