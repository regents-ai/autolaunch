defmodule Autolaunch.LaunchRpcClient do
  @moduledoc """
  The production Base client for direct-wallet launches, which prepares nothing yet.

  A review needs the deployed factory address, and that address plus its runtime
  admission is deployment evidence nobody has frozen. Until then no address this
  lane could read is admitted evidence, so `snapshot/1` refuses before it opens a
  connection rather than reviewing against a value nobody has reviewed. That
  refusal is also what keeps a future admission honest: a snapshot has to answer
  the factory, the strategy and the strategy's bound fee hook at one exact
  reviewed block, so a provider that cannot serve every one of those reads at a
  block hash stays unavailable rather than reviewing against a different
  history.

  `verify/3` is complete, because a hash may still have to be told the truth
  about. It reads only canonical state: a receipt above the safe head, or one in
  a block that is no longer canonical, stays pending rather than becoming an
  answer, and every factory read a launch is confirmed by is executed against the
  exact block its own event was mined in.
  """

  @behaviour Autolaunch.LaunchChainClient

  alias Autolaunch.Chain.{Abi, LaunchAbi, Rpc}

  @rpc_opts [client_key: :autolaunch_launch_http_client, log_scope: "autolaunch launch"]

  @impl true
  def snapshot(_request), do: {:error, :launch_preparation_unavailable}

  @impl true
  def verify(envelope, step, hash) do
    %{"to" => to, "data" => data} = step(envelope, step)

    with {:ok, block} <- Rpc.safe_block(@rpc_opts),
         {:ok, settled} <-
           Rpc.canonical_outcome(hash, envelope["expected_signer"], to, data, block, @rpc_opts),
         do: settled(settled, envelope, step)
  end

  defp settled(:pending, _envelope, _step), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _step), do: {:ok, %{outcome: :reverted}}

  defp settled({:success, logs}, envelope, step) do
    with {:ok, block} <- mined_block(logs), do: proved(envelope, step, logs, block)
  end

  # The allowance correction's own event and the allowance it left behind are
  # separate facts. This transaction was prepared here to set one exact
  # allowance, so only that exact `Approval` proves it did what it was reviewed
  # to do; the mined-block allowance is corroboration stored alongside it, and
  # the fresh pre-launch dispatch snapshot is the gate that actually decides
  # whether the launch may be handed to a wallet.
  defp proved(envelope, :approval, logs, block) do
    fee = fee(envelope)
    signer = envelope["expected_signer"]
    factory = argument(envelope, "factory")
    regent = argument(envelope, "regent")

    with true <- Abi.approval_recorded?(logs, regent, signer, factory, fee),
         {:ok, allowance} <-
           Rpc.call_uint(
             regent,
             Abi.encode_erc20("allowance", [signer, factory]),
             block,
             @rpc_opts
           ) do
      {:ok, %{outcome: :confirmed, result: %{"allowance" => Integer.to_string(allowance)}}}
    else
      false -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  # One `LaunchCreated` from the reviewed factory, naming exactly the reviewed
  # signer, treasury and raise; the exact fee branch the reviewed fee requires;
  # and a factory that already agrees with that event at the block it was mined
  # in. Anything less is `unverified`, never success.
  defp proved(envelope, :launch, logs, block) do
    factory = argument(envelope, "factory")

    with {:ok, event} <- LaunchAbi.launch_created(logs, factory),
         :ok <- reviewed(event, envelope),
         :ok <- fee_branch(logs, factory, event, envelope),
         :ok <- recorded(event, factory, block) do
      {:ok, %{outcome: :confirmed, result: result(event)}}
    else
      {:error, reason} -> {:error, reason}
      _contradiction -> {:ok, %{outcome: :unverified}}
    end
  end

  defp reviewed(event, envelope) do
    agreed(
      same?(event.launcher, envelope["expected_signer"]) and
        same?(event.treasury, argument(envelope, "treasury")) and
        event.required_regent_raised == atomic(envelope, "required_regent_raised_atomic")
    )
  end

  # A positive fee moves REGENT and must say so exactly once; a zero fee moves
  # nothing, so any fee event at all contradicts the review.
  defp fee_branch(logs, factory, event, envelope) do
    signer = envelope["expected_signer"]

    case fee(envelope) do
      0 ->
        agreed(not LaunchAbi.fee_collected?(logs, factory))

      fee ->
        collected = LaunchAbi.launch_fee_collected(logs, factory, event.launch_id, signer)
        agreed(match?({:ok, %{amount: ^fee}}, collected))
    end
  end

  defp recorded(event, factory, block) do
    with {:ok, words} <-
           Rpc.call_words(
             factory,
             LaunchAbi.encode_launches(event.launch_id),
             block,
             5,
             @rpc_opts
           ),
         {:ok, record} <- LaunchAbi.launch_record(words),
         {:ok, launch_id} <-
           Rpc.call_uint(
             factory,
             LaunchAbi.encode_launch_id_of_subject(event.subject),
             block,
             @rpc_opts
           ) do
      agrees(record, event, launch_id)
    else
      {:error, reason} -> {:error, reason}
      _contradiction -> :contradiction
    end
  end

  @identity [:launcher, :subject, :auction, :escrow, :treasury]

  defp agrees(record, event, launch_id),
    do: agreed(launch_id == event.launch_id and record == Map.take(event, @identity))

  defp agreed(true), do: :ok
  defp agreed(false), do: :contradiction

  defp result(event) do
    %{
      "launch_id" => Integer.to_string(event.launch_id),
      "subject" => event.subject,
      "auction" => event.auction,
      "escrow" => event.escrow,
      "start_block" => Integer.to_string(event.start_block),
      "end_block" => Integer.to_string(event.end_block)
    }
  end

  # The exact block this receipt's own logs were mined in, which
  # `canonical_outcome/6` has already proved canonical at or below the safe head.
  # Reading the factory there is what makes the record and the event one fact
  # rather than two states observed at different times.
  defp mined_block(logs) do
    case logs |> Enum.map(& &1["blockHash"]) |> Enum.uniq() do
      [hash] -> block_identity(hash)
      _absent_or_mixed -> {:error, :invalid_receipt}
    end
  end

  defp block_identity(hash) do
    if Rpc.valid_hash?(hash),
      do: {:ok, %{hash: String.downcase(hash)}},
      else: {:error, :invalid_receipt}
  end

  defp step(envelope, step) do
    current = Atom.to_string(step)
    Enum.find(argument(envelope, "steps"), &(&1["step"] == current))
  end

  defp fee(envelope), do: atomic(envelope, "expected_launch_fee_atomic")
  defp atomic(envelope, key), do: envelope |> argument(key) |> String.to_integer()
  defp argument(envelope, key), do: envelope["arguments"][key]

  defp same?(left, right), do: Autolaunch.Chain.Address.equal?(left, right)
end
