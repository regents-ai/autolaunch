defmodule Autolaunch.LabLaunchChainClient do
  @moduledoc false

  @behaviour Autolaunch.LaunchChainClient

  alias Autolaunch.Chain.{Abi, LaunchAbi}
  alias Autolaunch.{Lab, LabRpc}
  alias RegentChain.Address

  @impl true
  def snapshot(_request) do
    with {:ok, config, block, opts} <- LabRpc.current([:factory, :strategy, :regent]),
         {:ok, paused} <- LabRpc.bool(config, :factory, "launchesPaused()", [], block, opts),
         {:ok, strategy} <- LabRpc.address(config, :factory, "strategy()", [], block, opts),
         true <- Address.equal?(strategy, Lab.address!(config, :strategy)),
         {:ok, strategy_factory} <-
           LabRpc.address(config, :strategy, "factory()", [], block, opts),
         {:ok, hook} <- LabRpc.address(config, :strategy, "hook()", [], block, opts),
         true <- Address.equal?(hook, Lab.address!(config, :hook)),
         {:ok, lp_locker} <- LabRpc.address(config, :strategy, "lpLocker()", [], block, opts),
         true <- Address.equal?(lp_locker, Lab.address!(config, :lp_locker)),
         {:ok, terms} <- terms(config, block, opts) do
      {:ok,
       %{
         factory: Lab.address!(config, :factory),
         strategy: strategy,
         strategy_factory: strategy_factory,
         hook: hook,
         lp_locker: lp_locker,
         paused: paused,
         terms: terms,
         block: block,
         regent: Lab.address!(config, :regent)
       }}
    else
      false -> {:error, :lab_contract_mismatch}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @impl true
  def verify(%{"signer" => signer, "step" => step, "facts" => facts}, hash) do
    with {:ok, config} <- Lab.current(),
         {:ok, outcome} <- LabRpc.outcome(LabRpc.opts(config), signer, step, hash),
         do: settled(outcome, signer, facts, config)
  end

  # Every term is one of the strategy's constants, read with no argument.
  defp terms(config, block, opts) do
    LaunchAbi.terms()
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, terms} ->
      case LabRpc.uint(config, :strategy, LaunchAbi.term_signature(key), [], block, opts) do
        {:ok, value} -> {:cont, {:ok, Map.put(terms, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp settled(:pending, _signer, _facts, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _signer, _facts, _config), do: {:ok, %{outcome: :reverted}}

  defp settled({:success, logs}, signer, facts, config),
    do: verify_launch(logs, signer, facts, config)

  defp verify_launch(logs, signer, facts, config) do
    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, event} <- LaunchAbi.launch_created(logs, Lab.address!(config, :factory)),
         true <- Address.equal?(event.launcher, signer),
         true <- Address.equal?(event.treasury, facts["treasury"]),
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
end
