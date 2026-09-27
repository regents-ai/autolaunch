defmodule Autolaunch.SubjectWalletRpcClient do
  @moduledoc """
  The production Base client for subject wallet actions, which prepares nothing yet.

  A review needs the launch's real splitter and canonical receiver, and both are
  C5 address and runtime evidence that `490.8.2/.3` projection has still to make
  canonical. Until then no address this lane could read is admitted evidence, so
  `snapshot/1` refuses before it opens a connection rather than reviewing against
  a value nobody has frozen.

  `verify/3` is complete, because a hash may still have to be told the truth
  about. It reads only canonical state: a receipt above the safe head, or one in
  a block that is no longer canonical, stays pending rather than becoming an
  answer, and an approval advances only once its own allowance really holds.
  """

  @behaviour Autolaunch.SubjectWalletChainClient

  alias Autolaunch.Chain.{Abi, Rpc, SubjectAbi}

  @rpc_opts [client_key: :autolaunch_subject_wallet_http_client, log_scope: "autolaunch subject"]

  @impl true
  def snapshot(_request), do: {:error, :subject_wallet_preparation_unavailable}

  @impl true
  def verify(envelope, step, hash) do
    with {:ok, result} <- verify_with_evidence(envelope, step, hash),
         do: {:ok, Map.delete(result, :receipt)}
  end

  def verify_with_evidence(envelope, step, hash) do
    %{"to" => to, "data" => data} = step(envelope, step)

    with {:ok, block} <- Rpc.safe_block(@rpc_opts),
         {:ok, evidence} <-
           Rpc.canonical_outcome_evidence(
             hash,
             envelope["expected_signer"],
             to,
             data,
             block,
             @rpc_opts
           ),
         {:ok, result} <- settled(evidence.outcome, envelope, step, block),
         do: {:ok, Map.put(result, :receipt, evidence.receipt)}
  end

  defp settled(:pending, _envelope, _step, _block), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _step, _block), do: {:ok, %{outcome: :reverted}}
  defp settled({:success, logs}, envelope, step, block), do: proved(envelope, step, logs, block)

  # The approval's own event and the allowance it claims to have left behind are
  # separate facts. This transaction was prepared here to set one exact
  # allowance, so only that exact allowance proves it did what it was reviewed to
  # do; anything else is a state this review cannot vouch for.
  defp proved(envelope, :approval, logs, block) do
    %{"to" => token, "spender" => spender, "amount" => amount} = step(envelope, :approval)
    amount = String.to_integer(amount)
    signer = envelope["expected_signer"]

    with true <- Abi.approval_recorded?(logs, token, signer, spender, amount),
         {:ok, allowance} <-
           Rpc.call_uint(
             token,
             Abi.encode_erc20("allowance", [signer, spender]),
             block,
             @rpc_opts
           ) do
      {:ok, %{outcome: outcome(allowance >= amount)}}
    else
      false -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp proved(envelope, :action, logs, _block),
    do: action(envelope["arguments"]["kind"], envelope, logs)

  # The event supplies the actual result: a payment has to route exactly the
  # gross it reviewed, while a sweep learns the amount it really moved.
  defp action("pay", envelope, logs) do
    reviewed = amount(envelope)

    case routed(envelope, logs) do
      {:ok, %{gross: ^reviewed} = routed} ->
        {:ok, %{outcome: :confirmed, result: routed_result(routed)}}

      _contradiction ->
        {:ok, %{outcome: :unverified}}
    end
  end

  defp action("sweep", envelope, logs) do
    case routed(envelope, logs) do
      {:ok, routed} -> {:ok, %{outcome: :confirmed, result: routed_result(routed)}}
      :error -> {:ok, %{outcome: :unverified}}
    end
  end

  defp routed(envelope, logs),
    do:
      SubjectAbi.payment_routed(
        logs,
        argument(envelope, "receiver"),
        argument(envelope, "payment_reference"),
        argument(envelope, "token")
      )

  defp routed_result(%{gross: gross, note: note}),
    do: %{"gross" => Integer.to_string(gross), "note" => note}

  defp outcome(true), do: :confirmed
  defp outcome(false), do: :unverified

  defp step(envelope, step) do
    current = Atom.to_string(step)
    Enum.find(argument(envelope, "steps"), &(&1["step"] == current))
  end

  defp amount(envelope), do: envelope |> argument("amount_atomic") |> String.to_integer()

  defp argument(envelope, key), do: envelope["arguments"][key]
end
