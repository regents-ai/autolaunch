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

  defp proved(envelope, :action, logs, block),
    do: action(envelope["arguments"]["kind"], envelope, logs, block)

  # The exact staking events, for this signer and this reviewed amount.
  defp action("stake", envelope, logs, _block),
    do:
      settled_outcome(
        SubjectAbi.staked?(logs, splitter(envelope), signer(envelope), amount(envelope))
      )

  defp action("unstake", envelope, logs, _block),
    do:
      settled_outcome(
        SubjectAbi.unstaked?(logs, splitter(envelope), signer(envelope), amount(envelope))
      )

  # A canonical success with no `Claimed` log is a truthful no-op: the contract
  # returns early when nothing is owed, so nothing was available to claim.
  defp action("claim", envelope, logs, _block) do
    token = argument(envelope, "token")

    case SubjectAbi.claimed(logs, splitter(envelope), signer(envelope), bound_tokens(envelope)) do
      {:ok, claims} when claims == %{} ->
        claimed(%{})

      {:ok, %{^token => amount} = claims} when map_size(claims) == 1 ->
        claimed(%{token => amount})

      _contradiction ->
        {:ok, %{outcome: :unverified}}
    end
  end

  defp action("claim_all", envelope, logs, _block) do
    case SubjectAbi.claimed(logs, splitter(envelope), signer(envelope), bound_tokens(envelope)) do
      {:ok, claims} -> claimed(claims)
      :error -> {:ok, %{outcome: :unverified}}
    end
  end

  # The event supplies the actual result: a payment has to route exactly the
  # gross it reviewed, while a sweep learns the amount it really moved.
  defp action("pay", envelope, logs, _block) do
    reviewed = amount(envelope)

    case routed(envelope, logs) do
      {:ok, %{gross: ^reviewed} = routed} ->
        {:ok, %{outcome: :confirmed, result: routed_result(routed)}}

      _contradiction ->
        {:ok, %{outcome: :unverified}}
    end
  end

  defp action("sweep", envelope, logs, _block) do
    case routed(envelope, logs) do
      {:ok, routed} -> {:ok, %{outcome: :confirmed, result: routed_result(routed)}}
      :error -> {:ok, %{outcome: :unverified}}
    end
  end

  # The exact event is the authority. The receipt-block read is corroboration
  # only, so a later same-block write that moved the note on cannot turn the
  # exact event this transaction emitted into an unverified outcome.
  defp action("set_note", envelope, logs, block) do
    receiver = argument(envelope, "receiver")
    note = argument(envelope, "note")

    if SubjectAbi.receiver_note_updated?(logs, receiver, note) do
      corroborated(receiver, note, block)
    else
      {:ok, %{outcome: :unverified}}
    end
  end

  defp corroborated(receiver, note, block) do
    case Rpc.call_words(receiver, SubjectAbi.encode_read(:receiver_note), block, 1, @rpc_opts) do
      {:ok, [word]} ->
        {:ok,
         %{outcome: :confirmed, result: %{"note" => hex_word(word), "reviewed_note" => note}}}

      {:error, reason} ->
        {:error, reason}
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

  defp claimed(claims),
    do:
      {:ok,
       %{
         outcome: :confirmed,
         result: %{
           "claimed" =>
             Map.new(claims, fn {token, amount} -> {token, Integer.to_string(amount)} end)
         }
       }}

  defp settled_outcome(true), do: {:ok, %{outcome: :confirmed}}
  defp settled_outcome(false), do: {:ok, %{outcome: :unverified}}

  defp outcome(true), do: :confirmed
  defp outcome(false), do: :unverified

  defp step(envelope, step) do
    current = Atom.to_string(step)
    Enum.find(argument(envelope, "steps"), &(&1["step"] == current))
  end

  defp splitter(envelope), do: argument(envelope, "splitter")
  defp signer(envelope), do: envelope["expected_signer"]
  defp amount(envelope), do: envelope |> argument("amount_atomic") |> String.to_integer()
  defp bound_tokens(envelope), do: envelope |> argument("bound_tokens") |> Map.values()

  defp argument(envelope, key), do: envelope["arguments"][key]

  defp hex_word(value),
    do:
      "0x" <> (value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))
end
