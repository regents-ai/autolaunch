defmodule Autolaunch.LabLaunchChainClient do
  @moduledoc false

  @behaviour Autolaunch.LaunchChainClient

  alias Autolaunch.Chain.{Abi, Address}
  alias Autolaunch.{Lab, LabAbi, LabRpc}

  @term_signatures %{
    start_delay_blocks: "START_DELAY_BLOCKS()",
    auction_duration_blocks: "AUCTION_DURATION_BLOCKS()",
    claim_delay_blocks: "CLAIM_DELAY_BLOCKS()",
    migration_delay_blocks: "MIGRATION_DELAY_BLOCKS()",
    floor_price_q96: "FLOOR_PRICE_Q96()",
    bid_tick_q96: "BID_TICK_Q96()",
    auction_allocation: "AUCTION_ALLOCATION()",
    reserve_allocation: "RESERVE_ALLOCATION()",
    pending_allocation: "PENDING_ALLOCATION()",
    pool_fee: "POOL_FEE()",
    pool_tick_spacing: "POOL_TICK_SPACING()",
    max_reachable_raise: "MAX_REACHABLE_RAISE()"
  }

  @impl true
  def snapshot(%{signer: signer}) do
    with {:ok, config, block, opts} <- LabRpc.current([:factory, :strategy, :regent]),
         {:ok, fee} <- LabRpc.uint(config, :factory, "launchFee()", [], block, opts),
         {:ok, paused} <- LabRpc.bool(config, :factory, "launchesPaused()", [], block, opts),
         {:ok, strategy} <- LabRpc.address(config, :factory, "strategy()", [], block, opts),
         true <- Address.equal?(strategy, Lab.address!(config, :strategy)),
         {:ok, strategy_factory} <-
           LabRpc.address(config, :strategy, "factory()", [], block, opts),
         {:ok, hook} <- LabRpc.address(config, :strategy, "hook()", [], block, opts),
         true <- Address.equal?(hook, Lab.address!(config, :hook)),
         {:ok, balance} <-
           LabRpc.uint(config, :regent, "balanceOf(address)", [signer], block, opts),
         {:ok, allowance} <-
           LabRpc.uint(
             config,
             :regent,
             "allowance(address,address)",
             [signer, Lab.address!(config, :factory)],
             block,
             opts
           ),
         {:ok, terms} <- terms(config, block, opts) do
      {:ok,
       %{
         factory: Lab.address!(config, :factory),
         strategy: strategy,
         strategy_factory: strategy_factory,
         fee: fee,
         allowance: allowance,
         balance: balance,
         hook: hook,
         paused: paused,
         terms: terms,
         block: block,
         regent: Lab.address!(config, :regent),
         lab_binding: Lab.binding(config, [:factory, :strategy, :hook, :regent])
       }}
    else
      false -> {:error, :lab_contract_mismatch}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @impl true
  def verify(envelope, step, hash) do
    with true <-
           Autolaunch.Chain.Envelope.valid_for_confirmation?(envelope,
             resource: "autolaunch_launch",
             chain_id: Lab.chain_id()
           ),
         true <-
           Lab.binding_matches?(envelope["metadata"]["lab"], [:factory, :strategy, :hook, :regent]),
         {:ok, config} <- Lab.current(),
         current <- current_step(envelope, step),
         {:ok, outcome} <- LabRpc.canonical_outcome(config, envelope, current, hash) do
      settled(outcome, envelope, step, config)
    else
      false -> {:error, :lab_config_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terms(config, block, opts) do
    Enum.reduce_while(@term_signatures, {:ok, %{}}, fn {key, signature}, {:ok, terms} ->
      case LabRpc.uint(config, :strategy, signature, [], block, opts) do
        {:ok, value} -> {:cont, {:ok, Map.put(terms, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp settled(:pending, _envelope, _step, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _step, _config), do: {:ok, %{outcome: :reverted}}

  defp settled({:success, logs}, envelope, :approval, config),
    do: verify_approval(logs, envelope, config)

  defp settled({:success, logs}, envelope, :launch, config),
    do: verify_launch(logs, envelope, config)

  defp verify_approval(logs, envelope, config) do
    with {:ok, block} <- LabRpc.block_from_logs(logs),
         step <- current_step(envelope, :approval),
         amount <- String.to_integer(step["amount"]),
         true <-
           Abi.approval_recorded?(
             logs,
             Lab.address!(config, :regent),
             envelope["expected_signer"],
             Lab.address!(config, :factory),
             amount
           ),
         opts <- LabRpc.opts(config),
         {:ok, allowance} <-
           LabRpc.uint(
             config,
             :regent,
             "allowance(address,address)",
             [envelope["expected_signer"], Lab.address!(config, :factory)],
             block,
             opts
           ) do
      {:ok, %{outcome: if(allowance == amount, do: :confirmed, else: :unverified)}}
    else
      false -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_launch(logs, envelope, config) do
    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, event} <- launch_created(logs, config),
         true <- Address.equal?(event.launcher, envelope["expected_signer"]),
         true <- Address.equal?(event.treasury, envelope["arguments"]["treasury"]),
         true <-
           event.required_regent_raised == integer(envelope, "required_regent_raised_atomic"),
         opts <- LabRpc.opts(config),
         {:ok, record_words} <-
           LabRpc.words(config, :factory, "launches(uint256)", [event.launch_id], 5, block, opts),
         {:ok, launch_id} <-
           LabRpc.uint(
             config,
             :factory,
             "launchIdOfSubject(address)",
             [event.subject],
             block,
             opts
           ),
         true <- launch_id == event.launch_id,
         true <- record_matches?(record_words, event) do
      {:ok,
       %{
         outcome: :confirmed,
         result: %{
           "launch_id" => Integer.to_string(event.launch_id),
           "subject" => event.subject,
           "auction" => event.auction,
           "escrow" => event.escrow,
           "treasury" => event.treasury,
           "start_block" => Integer.to_string(event.start_block),
           "end_block" => Integer.to_string(event.end_block),
           "local_block_hash" => block.hash
         }
       }}
    else
      false -> {:ok, %{outcome: :unverified}}
      :error -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp launch_created(logs, config) do
    signature =
      "LaunchCreated(uint256,address,address,address,address,address,uint128,uint64,uint64)"

    with {:ok, {[launch_id, launcher_word, subject_word], data}} <-
           LabAbi.event_words(
             Lab.abi!(config, :factory),
             signature,
             logs,
             Lab.address!(config, :factory)
           ),
         [auction_word, escrow_word, treasury_word, required_raise, start_block, end_block] <-
           data,
         {:ok, launcher} <- Abi.word_address(launcher_word),
         {:ok, subject} <- Abi.word_address(subject_word),
         {:ok, auction} <- Abi.word_address(auction_word),
         {:ok, escrow} <- Abi.word_address(escrow_word),
         {:ok, treasury} <- Abi.word_address(treasury_word) do
      {:ok,
       %{
         launch_id: launch_id,
         launcher: launcher,
         subject: subject,
         auction: auction,
         escrow: escrow,
         treasury: treasury,
         required_regent_raised: required_raise,
         start_block: start_block,
         end_block: end_block
       }}
    else
      _ -> :error
    end
  end

  defp record_matches?([launcher, subject, auction, escrow, treasury], event) do
    with {:ok, launcher} <- Abi.word_address(launcher),
         {:ok, subject} <- Abi.word_address(subject),
         {:ok, auction} <- Abi.word_address(auction),
         {:ok, escrow} <- Abi.word_address(escrow),
         {:ok, treasury} <- Abi.word_address(treasury) do
      Enum.all?(
        [
          {launcher, event.launcher},
          {subject, event.subject},
          {auction, event.auction},
          {escrow, event.escrow},
          {treasury, event.treasury}
        ],
        fn {left, right} -> Address.equal?(left, right) end
      )
    else
      _ -> false
    end
  end

  defp record_matches?(_words, _event), do: false

  defp current_step(envelope, step) do
    name = Atom.to_string(step)
    Enum.find(envelope["arguments"]["steps"], &(&1["step"] == name))
  end

  defp integer(envelope, key), do: envelope["arguments"][key] |> String.to_integer()
end
