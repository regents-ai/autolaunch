defmodule Autolaunch.AuctionFinish.Launchpads do
  @moduledoc """
  The launchpads this site describes, and what the finisher needs from each:
  how many launches it has, one launch's auction, migration block and state,
  and the `migrate` call that finishes it.

  - Base Revstake: the factory numbers the launches and the strategy holds
    each auction's distribution and finishes it with `migrate(address auction)`.
  - Base Memestake and Robinhood Memestake: the launchpad numbers the launches,
    holds them and finishes one with `migrate(uint256 launchId)`.

  Every record read here is a fixed tuple of words; the positions below are
  the deployed contracts' field order.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Lab
  alias Autolaunch.LabAbi
  alias Autolaunch.LabRpc
  alias Autolaunch.Robinhood.BlockClock
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab

  # The launch lifecycle every launchpad shares: 0 is no launch.
  @states %{1 => :running, 2 => :graduated, 3 => :failed}

  @scope "auction finisher"

  @doc "Every launchpad the loaded deployment descriptions name."
  def configured do
    [
      Lab.configured?() && revstake(Lab.current!()),
      StocksLab.configured?() && memestake(StocksLab.current!()),
      RobinhoodLab.configured?() && robinhood(RobinhoodLab.current())
    ]
    |> Enum.filter(& &1)
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
         auction = address(Enum.at(launch, 2)),
         {:ok, distribution} <-
           words(
             pad.strategy,
             pad.strategy_abi,
             "distribution(address)",
             [auction],
             18,
             block,
             pad
           ) do
      {:ok,
       %{
         auction: auction,
         migration_block: Enum.at(distribution, 4),
         state: Map.fetch!(@states, Enum.at(distribution, 0))
       }}
    end
  end

  def launch(pad, launch_id, block) do
    {count, auction_at, migration_at, state_at} = layout(pad.launchpad)

    with {:ok, launch} <-
           words(pad.contract, pad.abi, "launches(uint256)", [launch_id], count, block, pad) do
      {:ok,
       %{
         auction: address(Enum.at(launch, auction_at)),
         migration_block: Enum.at(launch, migration_at),
         state: Map.fetch!(@states, Enum.at(launch, state_at))
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
      contract: Lab.address!(config, :factory),
      abi: Lab.abi!(config, :factory),
      strategy: Lab.address!(config, :strategy),
      strategy_abi: Lab.abi!(config, :strategy),
      opts: LabRpc.opts(config, @scope)
    }
  end

  defp memestake(config) do
    %{
      launchpad: :base_memestake,
      chain_id: config.chain_id,
      contract: StocksLab.address!(config, :launchpad),
      abi: StocksLab.abi!(config, :launchpad),
      opts: StocksLab.rpc_opts(config, @scope)
    }
  end

  defp robinhood({:ok, config}) do
    %{
      launchpad: :robinhood_memestake,
      chain_id: config.chain_id,
      contract: RobinhoodLab.address!(config, :stocks_launchpad),
      abi: RobinhoodLab.abi!(config, :stocks_launchpad),
      opts: RobinhoodLab.rpc_opts(config)
    }
  end

  # {words in a launch, auction, migration block, lifecycle}
  defp layout(:base_memestake), do: {20, 3, 8, 11}
  defp layout(:robinhood_memestake), do: {18, 3, 7, 10}

  defp words(to, abi, signature, arguments, count, block, pad),
    do: Rpc.call_words(to, LabAbi.encode(abi, signature, arguments), block, count, pad.opts)

  defp address(word),
    do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(word, 16)), 40, "0")
end
