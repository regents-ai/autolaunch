defmodule Autolaunch.AuctionFinish.Sender do
  @moduledoc """
  Sends `migrate` from the finishing wallet, and settles what it sent.

  A send reserves the nonce, signs, and commits the signed transaction as an
  `AuctionFinish.Transaction` before anything is broadcast, so a failure after
  the broadcast, or a worker that dies there, leaves the transaction recorded.
  Reserving and recording hold a database lock for the chain and the wallet,
  so two machines never reserve the same nonce: the nonce is the wallet's
  pending count, or one above the highest this site has recorded if that is
  higher, which covers a recorded transaction not yet broadcast.

  A launch with a recorded transaction the chain has not settled is never sent
  another. `settle/2` reads the recorded one first: its receipt settles it as
  mined or reverted; one the network holds is waited for; one whose nonce the
  wallet has already used is dropped; and one the network never saw is
  broadcast again, exactly as signed.

  The call is simulated before signing, so a launch someone else has just
  finished costs nothing. The fee allows the base fee to double before the
  transaction stops being included.
  """

  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionFinish.Wallet
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Repo

  @actor %System{}

  @doc """
  Settles the launch's recorded transaction, if it has one: `{:ok, :clear}`
  when there is nothing left unsettled, `{:ok, :waiting}` while there is.
  """
  def settle(pad, finish) do
    case Autolaunch.unsettled_auction_finish_transaction(finish.id, actor: @actor) do
      {:ok, nil} -> {:ok, :clear}
      {:ok, transaction} -> reconcile(pad, transaction)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reserves a nonce, signs and records the call, then broadcasts it."
  def send_call(pad, finish, %{to: to, data: data}) do
    wallet = Wallet.configured!()
    opts = pad.opts

    with {:ok, gas} <-
           quantity("eth_estimateGas", [%{from: wallet.address, to: to, data: data}], opts),
         {:ok, tip} <- quantity("eth_maxPriorityFeePerGas", [], opts),
         {:ok, base_fee} <- base_fee(opts),
         {:ok, transaction} <-
           record(pad, finish, wallet, %{
             chain_id: pad.chain_id,
             max_priority_fee: tip,
             max_fee: 2 * base_fee + tip,
             gas_limit: gas + div(gas, 5),
             to: to,
             data: data
           }),
         {:ok, _hash} <- broadcast(pad, transaction),
         do: {:ok, transaction}
  end

  # The nonce is read from the chain inside the lock, because the lock is what
  # makes the read and the recorded nonces one decision.
  defp record(pad, finish, wallet, call) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key(pad.chain_id, wallet.address)])

      with {:ok, pending} <-
             quantity("eth_getTransactionCount", [wallet.address, "pending"], pad.opts),
           {:ok, recorded} <- highest_recorded(pad.chain_id, wallet.address),
           nonce = max(pending, recorded + 1),
           {raw, hash} = Wallet.sign(wallet, Map.put(call, :nonce, nonce)),
           {:ok, transaction} <-
             Autolaunch.record_auction_finish_transaction(
               %{
                 auction_finish_id: finish.id,
                 chain_id: pad.chain_id,
                 signer: wallet.address,
                 nonce: nonce,
                 transaction_hash: hash,
                 raw_transaction: raw
               },
               actor: @actor
             ) do
        transaction
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp highest_recorded(chain_id, signer) do
    case Autolaunch.highest_auction_finish_nonce(chain_id, signer, actor: @actor) do
      {:ok, nil} -> {:ok, -1}
      {:ok, transaction} -> {:ok, transaction.nonce}
      {:error, reason} -> {:error, reason}
    end
  end

  # The wallet's mined count is read before the receipt, so a count past this
  # nonce with no receipt after it means another transaction used the nonce.
  defp reconcile(pad, transaction) do
    opts = pad.opts

    with {:ok, mined} <-
           quantity("eth_getTransactionCount", [transaction.signer, "latest"], opts),
         {:ok, receipt} <-
           Rpc.request("eth_getTransactionReceipt", [transaction.transaction_hash], opts),
         {:ok, seen} <-
           Rpc.request("eth_getTransactionByHash", [transaction.transaction_hash], opts) do
      case {receipt, seen} do
        {%{"status" => "0x1"}, _seen} -> settled(transaction, :mined)
        {%{"status" => "0x0"}, _seen} -> settled(transaction, :reverted)
        {nil, %{}} -> {:ok, :waiting}
        {nil, nil} when mined > transaction.nonce -> settled(transaction, :dropped)
        {nil, nil} -> rebroadcast(pad, transaction)
        _malformed -> {:error, :invalid_chain_response}
      end
    end
  end

  defp settled(transaction, outcome) do
    with {:ok, _transaction} <-
           Autolaunch.settle_auction_finish_transaction(transaction, outcome, actor: @actor),
         do: {:ok, :clear}
  end

  # The network may refuse the bytes as already known or as too late; the next
  # settle reads which it was, so a refusal here is only reported.
  defp rebroadcast(pad, transaction) do
    case broadcast(pad, transaction) do
      {:ok, _hash} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "auction finisher could not rebroadcast #{transaction.transaction_hash}: #{inspect(reason)}"
        )
    end

    {:ok, :waiting}
  end

  defp broadcast(pad, transaction),
    do: Rpc.request("eth_sendRawTransaction", [transaction.raw_transaction], pad.opts)

  defp lock_key(chain_id, signer) do
    <<key::signed-64, _rest::binary>> =
      :crypto.hash(:sha256, "auction finisher #{chain_id} #{String.downcase(signer)}")

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
