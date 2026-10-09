defmodule Autolaunch.AuctionFinish.Launchpads do
  @moduledoc """
  The launchpads this site describes, and what finishing a launch needs from
  each: how many launches it has, one launch's auction, migration block and
  state, and the `migrate` call that finishes it. The finisher drives the
  second launchpads (`configured/0`); an auction page's Finish button reaches
  the launchpad its own auction runs on, first or second (`for_auction/1`).

  - Base Revstake: the factory numbers the launches and the strategy holds
    each auction's distribution and finishes it with `migrate(address auction)`.
  - Base Memestake and Robinhood Memestake: the launchpad numbers the launches,
    holds them and finishes one with `migrate(uint256 launchId)`.

  Every record read here is a fixed tuple of words; the positions below are
  the deployed contracts' field order.
  """

  alias Autolaunch.Chain.{Client, Rpc}
  alias Autolaunch.Lab
  alias Autolaunch.LabAbi
  alias Autolaunch.LabRpc
  alias Autolaunch.Robinhood.BlockClock
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  # The launch lifecycle every launchpad shares: 0 is no launch.
  @states %{1 => :running, 2 => :graduated, 3 => :failed}

  @scope "auction finisher"

  @doc "Every second launchpad the loaded deployment descriptions name."
  def configured do
    [
      Lab.configured?() && {:ok, revstake(Lab.current!())},
      StocksLab.configured?() && memestake(StocksLab.current(), :v2),
      RobinhoodLab.configured?() && robinhood(RobinhoodLab.current(), :v2)
    ]
    |> Enum.flat_map(fn
      false -> []
      {:ok, pad} -> [pad]
    end)
  end

  @doc """
  The launchpad a listed auction runs on: the Robinhood one on Robinhood's
  chain, otherwise Revstake for an agent auction and Memestake for a stocks
  one, each of the auction's own contracts version.
  """
  def for_auction(%{chain_id: chain_id, kind: kind, contracts_version: version}) do
    cond do
      RobinhoodLab.chain?(chain_id) -> robinhood(RobinhoodLab.current(), version)
      kind == :agent -> with {:ok, config} <- Lab.current(), do: {:ok, revstake(config)}
      true -> memestake(StocksLab.current(), version)
    end
  end

  @doc "The configured launchpad a recorded launch belongs to."
  def for_launch!(%{chain_id: chain_id, contract: contract}) do
    Enum.find(configured(), &(&1.chain_id == chain_id and &1.contract == contract)) ||
      raise "no configured launchpad is #{contract} on chain #{chain_id}"
  end

  @doc """
  The block a launchpad keeps time by at a read block: the rollup block on
  Robinhood (`Autolaunch.Robinhood.BlockClock`), the block itself on Base.
  """
  def clock(%{launchpad: :robinhood_memestake} = pad, block), do: BlockClock.read(block, pad.opts)
  def clock(_pad, block), do: {:ok, block.number}

  @doc "The highest launch id so far: `nextLaunchId` less one."
  def last_launch_id(pad, block) do
    with {:ok, next} <-
           Rpc.call_uint(
             pad.contract,
             LabAbi.encode(pad.abi, "nextLaunchId()", []),
             block,
             pad.opts
           ),
         do: {:ok, next - 1}
  end

  @doc "One launch's auction, migration block and state."
  def launch(%{launchpad: :base_revstake} = pad, launch_id, block) do
    with {:ok, launch} <-
           words(pad.contract, pad.abi, "launches(uint256)", [launch_id], 5, block, pad),
         do: distribution(pad, address(Enum.at(launch, 2)), block)
  end

  def launch(pad, launch_id, block) do
    with {:ok, words} <-
           words(
             pad.contract,
             pad.abi,
             "launches(uint256)",
             [launch_id],
             pad.shape.record_words,
             block,
             pad
           ) do
      launch = pad.records.record(pad.shape, words)

      {:ok,
       %{
         auction: address(launch.auction),
         migration_block: launch.migration_block,
         state: Map.fetch!(@states, launch.lifecycle)
       }}
    end
  end

  @doc """
  The launch of the auction at `auction`, as `launch/3` reads it, with the
  launch id `migrate_call/2` names on a Memestake launchpad.
  """
  def launch_of_auction(%{launchpad: :base_revstake} = pad, auction, block),
    do: distribution(pad, auction, block)

  def launch_of_auction(pad, auction, block) do
    with {:ok, launch_id} <-
           Rpc.call_uint(
             pad.contract,
             LabAbi.encode(pad.abi, "launchIdOfAuction(address)", [auction]),
             block,
             pad.opts
           ),
         {:ok, launch} <- launch(pad, launch_id, block),
         do: {:ok, Map.put(launch, :launch_id, launch_id)}
  end

  # The strategy holds each Revstake auction's lifecycle and migration block.
  defp distribution(pad, auction, block) do
    with {:ok, distribution} <-
           words(
             pad.strategy,
             pad.strategy_abi,
             "distribution(address)",
             [auction],
             LabAbi.distribution_words(),
             block,
             pad
           ) do
      distribution = LabAbi.distribution(distribution)

      {:ok,
       %{
         auction: auction,
         migration_block: distribution.migration_block,
         state: Map.fetch!(@states, distribution.lifecycle)
       }}
    end
  end

  @doc "The contract and calldata that finish a recorded launch."
  def migrate_call(%{launchpad: :base_revstake} = pad, launch),
    do: %{
      to: pad.strategy,
      data: LabAbi.encode(pad.strategy_abi, "migrate(address)", [launch.auction])
    }

  def migrate_call(pad, launch),
    do: %{to: pad.contract, data: LabAbi.encode(pad.abi, "migrate(uint256)", [launch.launch_id])}

  defp revstake(config) do
    %{
      launchpad: :base_revstake,
      chain_id: config.chain_id,
      chain: Client.chain(config),
      contract: Lab.address!(config, :factory),
      abi: Lab.abi!(config, :factory),
      strategy: Lab.address!(config, :strategy),
      strategy_abi: Lab.abi!(config, :strategy),
      opts: LabRpc.opts(config, @scope)
    }
  end

  defp memestake({:ok, config}, version) do
    with {:ok, contracts} <- StocksLab.contracts(config, version) do
      {:ok,
       %{
         launchpad: :base_memestake,
         chain_id: config.chain_id,
         chain: Client.chain(config),
         contract: contracts.launchpad,
         abi: contracts.abis["launchpad"],
         shape: contracts,
         records: StocksLabAbi,
         opts: StocksLab.rpc_opts(config, @scope)
       }}
    end
  end

  defp memestake(error, _version), do: error

  defp robinhood({:ok, config}, version) do
    with {:ok, contracts} <- RobinhoodLab.contracts(config, version) do
      {:ok,
       %{
         launchpad: :robinhood_memestake,
         chain_id: config.chain_id,
         chain: Client.chain(config),
         contract: contracts.launchpad,
         abi: contracts.abis["launchpad"],
         shape: contracts,
         records: RobinhoodLabAbi,
         opts: RobinhoodLab.rpc_opts(config)
       }}
    end
  end

  defp robinhood(error, _version), do: error

  defp words(to, abi, signature, arguments, count, block, pad),
    do: Rpc.call_words(to, LabAbi.encode(abi, signature, arguments), block, count, pad.opts)

  defp address(word),
    do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(word, 16)), 40, "0")
end
