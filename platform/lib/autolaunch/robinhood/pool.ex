defmodule Autolaunch.Robinhood.Pool do
  @moduledoc """
  Read-only staking facts for one graduated Robinhood memestock launch, read
  from the local Robinhood lab by the auction's address: the chain is the only
  record of these launches.

  A graduated launch trades in a NEW/STOCK pool charged by the Robinhood fee
  hook and locked in the launchpad's LP locker, whose fees flow to the
  launch's memestock splitter. Everything is read at one latest block: the
  launch record and its pool id, the NEW token, the STOCK it trades against,
  the locked positions with what a collection would deposit now, the hook's
  staker lane and the splitter's totals. Nothing here writes, signs or caches.
  """

  alias Autolaunch.Chain.{Abi, Rpc}

  alias Autolaunch.{LabAbi, Pool, PoolRange, PriceHistory, RewardHistory}
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.{Assets, FeeSchedule}
  alias RegentChain.Address

  @token_decimals 18
  @usdg_decimals 6
  @graduated 2
  # Every Robinhood memestock pool is created with this tick spacing and the
  # fee schedule's pool fee; the fee hook refuses any other.
  @tick_spacing 60

  # Concrete-contract read the pinned interface ABIs do not carry: `ownerOf(uint256)`.
  @owner_of_selector "0x6352211e"

  @type t :: map()

  @doc """
  The lab's staking facts for one graduated auction, or why they cannot be
  read. The auction is its stored row, or any map naming its
  `auction_address` and `contracts_version`: a launch reads only the
  launchpad, hook and locker of its own version.
  """
  @spec read(map()) :: {:ok, t()} | {:error, atom()}
  def read(auction) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         do: read_at(auction, config, block, opts)
  end

  @doc "The same facts at a block already read, on the deployment it was read with."
  @spec read_at(map(), map(), Rpc.block(), keyword()) :: {:ok, t()} | {:error, atom()}
  def read_at(auction, config, block, opts) do
    with {:ok, launch} <- launch_record(auction, config, block, opts),
         {:ok, stock} <- Assets.fetch(Lab.chain_id(), launch.stock),
         {:ok, symbol} <-
           Rpc.call_string(launch.new_token, LabAbi.selector("symbol()"), block, opts),
         {:ok, current} <-
           Pool.pool_state(
             Lab.address!(config, :pool_manager),
             launch.pool_id,
             currency0?(launch.new_token, launch.stock),
             @token_decimals,
             stock.decimals,
             block,
             opts
           ),
         {:ok, positions} <- positions(config, launch, stock, current, block, opts),
         {:ok, fees} <- fees(config, launch, stock, block, opts),
         # The launch's migration block is on the rollup clock, not the block
         # numbers logs carry, so the pool's logs are read from the chain's start.
         {:ok, rewards} <- RewardHistory.recognized(:memestake, launch.splitter, 0, block, opts),
         {:ok, prices} <-
           PriceHistory.pool(
             %{
               pool_manager: Lab.address!(config, :pool_manager),
               pool_id: launch.pool_id,
               token_is_currency0?: currency0?(launch.new_token, launch.stock),
               currency_decimals: stock.decimals
             },
             0,
             block,
             opts
           ) do
      {:ok,
       %{
         kind: :stocks,
         chain: :robinhood,
         block: block,
         launch_id: launch.launch_id,
         pool_id: launch.pool_id,
         token: %{address: launch.new_token, symbol: symbol, decimals: @token_decimals},
         currency: %{address: launch.stock, symbol: stock.symbol, decimals: stock.decimals},
         token_is_currency0?: currency0?(launch.new_token, launch.stock),
         pool_fee: FeeSchedule.pool_fee(:robinhood, launch.contracts.version),
         tick_spacing: @tick_spacing,
         version: launch.contracts.version,
         launchpad: launch.contracts.launchpad,
         hook: launch.contracts.hook,
         locker: launch.contracts.locker,
         pool_manager: Lab.address!(config, :pool_manager),
         logs_from: 0,
         current: current,
         positions: positions,
         fees: fees,
         rewards: rewards,
         prices: prices,
         vesting: launch.vesting
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  What a reader of the pool's trades needs, for one graduated auction (as
  `read/1` takes it): the PoolManager, the pool id, the token, which side of the pool it
  is on and the stock it trades against. The launch's migration block is on
  the rollup clock, not the block numbers logs carry, so no opening block is
  given.
  """
  @spec swap_source(map(), map(), Rpc.block(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def swap_source(auction, config, block, opts) do
    with {:ok, launch} <- launch_record(auction, config, block, opts),
         {:ok, stock} <- Assets.fetch(Lab.chain_id(), launch.stock) do
      {:ok,
       %{
         pool_manager: Lab.address!(config, :pool_manager),
         pool_id: launch.pool_id,
         token: launch.new_token,
         token_is_currency0?: currency0?(launch.new_token, launch.stock),
         currency_symbol: stock.symbol,
         currency_decimals: stock.decimals,
         from_block: nil
       }}
    end
  end

  @doc """
  Every graduated launch on each launchpad the deployment names, at one block,
  newest first: its id, its token, its auction and the launchpad version it
  runs on. Launch ids run from 1 to `nextLaunchId() - 1` on each launchpad.
  """
  @spec graduated(map(), map(), keyword()) ::
          {:ok,
           [
             %{
               launch_id: pos_integer(),
               token: String.t(),
               auction: String.t(),
               contracts_version: :v1 | :v2
             }
           ]}
          | {:error, atom()}
  def graduated(config, block, opts) do
    config
    |> Lab.versions()
    |> Enum.reduce_while({:ok, []}, fn version, {:ok, found} ->
      case graduated_on(config, version, block, opts) do
        {:ok, launches} -> {:cont, {:ok, found ++ launches}}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  The REGENT lane of one graduated launch, as `graduated/3` lists it, at
  `block`: the stock it trades against and the lane's figures, atomic amounts
  included.
  """
  @spec regent_lane(map(), map(), Rpc.block(), keyword()) :: {:ok, map()} | {:error, atom()}
  def regent_lane(launch, config, block, opts) do
    with {:ok, record} <-
           launch_record(
             %{auction_address: launch.auction, contracts_version: launch.contracts_version},
             config,
             block,
             opts
           ),
         {:ok, stock} <- Assets.fetch(Lab.chain_id(), record.stock),
         {:ok, %{regent: regent}} <-
           Pool.lanes(
             record.contracts,
             record.pool_id,
             stock.decimals,
             @usdg_decimals,
             block,
             opts
           ) do
      {:ok,
       Map.put(regent, :stock, %{
         address: String.downcase(record.stock),
         symbol: stock.symbol,
         decimals: stock.decimals
       })}
    end
  end

  defp graduated_on(config, version, block, opts) do
    with {:ok, contracts} <- Lab.contracts(config, version),
         {:ok, next_id} <- launchpad_uint(contracts, "nextLaunchId()", [], block, opts) do
      Enum.reduce_while(
        1..(next_id - 1)//1,
        {:ok, []},
        &collect_graduated(&1, &2, contracts, block, opts)
      )
    end
  end

  defp collect_graduated(launch_id, {:ok, found}, contracts, block, opts) do
    case graduated_launch(contracts, launch_id, block, opts) do
      {:ok, nil} -> {:cont, {:ok, found}}
      {:ok, launch} -> {:cont, {:ok, [launch | found]}}
      error -> {:halt, error}
    end
  end

  defp graduated_launch(contracts, launch_id, block, opts) do
    with {:ok, words} <-
           launchpad_words(
             contracts,
             "launches(uint256)",
             [launch_id],
             contracts.record_words,
             block,
             opts
           ) do
      case launch(RobinhoodLabAbi.record(contracts, words)) do
        {:ok, launch} ->
          {:ok,
           %{
             launch_id: launch_id,
             token: launch.new_token,
             auction: launch.auction,
             contracts_version: contracts.version
           }}

        {:error, :not_graduated} ->
          {:ok, nil}

        error ->
          error
      end
    end
  end

  defp launch_record(auction, config, block, opts) do
    with {:ok, contracts} <- Lab.contracts(config, auction.contracts_version),
         {:ok, address} <- Address.normalize(auction.auction_address) |> normalized(),
         {:ok, launch_id} <-
           launchpad_uint(contracts, "launchIdOfAuction(address)", [address], block, opts),
         true <- launch_id > 0 || {:error, :unknown_auction},
         {:ok, words} <-
           launchpad_words(
             contracts,
             "launches(uint256)",
             [launch_id],
             contracts.record_words,
             block,
             opts
           ),
         record = RobinhoodLabAbi.record(contracts, words),
         {:ok, launch} <- launch(record),
         {:ok, second} <- second_position(contracts, record, launch_id, block, opts),
         {:ok, vesting} <- creator_vesting(contracts, record, launch_id, block, opts) do
      {:ok,
       Map.merge(launch, %{
         launch_id: launch_id,
         contracts: contracts,
         second: second,
         vesting: vesting
       })}
    end
  end

  # The second launchpad vests 1% of each launch's supply to its creator.
  defp creator_vesting(%{version: :v1}, _record, _launch_id, _block, _opts), do: {:ok, nil}

  defp creator_vesting(%{version: :v2} = contracts, record, launch_id, block, opts) do
    with {:ok, releasable} <-
           launchpad_uint(contracts, "creatorReleasable(uint256)", [launch_id], block, opts),
         do: Pool.vesting(record, releasable)
  end

  # Each launch's second locked position: the first launchpad keeps a
  # stock-only one in `stockRecords`, the second a token-only one in its record.
  defp second_position(%{version: :v1} = contracts, _record, launch_id, block, opts) do
    with {:ok, [token_id, used]} <-
           launchpad_words(contracts, "stockRecords(uint256)", [launch_id], 2, block, opts),
         do: {:ok, %{key: :stock_only, token_id: token_id, used: used}}
  end

  defp second_position(%{version: :v2}, record, _launch_id, _block, _opts),
    do: {:ok, %{key: :new_only, token_id: record.new_only_token_id, used: record.new_only_used}}

  defp normalized({:ok, address}), do: {:ok, address}
  defp normalized(:error), do: {:error, :invalid_auction}

  defp launch(record) do
    with {:ok, new_token} <- Abi.word_address(record.new_token),
         {:ok, stock} <- Abi.word_address(record.currency),
         {:ok, auction} <- Abi.word_address(record.auction),
         @graduated <- record.lifecycle,
         {:ok, splitter} <- Abi.word_address(record.splitter) do
      {:ok,
       %{
         new_token: new_token,
         stock: stock,
         auction: auction,
         migration_block: record.migration_block,
         pool_id: bytes32(record.pool_id),
         splitter: splitter,
         lp_token_id: record.lp_token_id,
         lp_stock_used: record.lp_currency_used,
         lp_new_used: record.lp_new_used
       }}
    else
      :error -> {:error, :invalid_chain_response}
      _lifecycle -> {:error, :not_graduated}
    end
  end

  # Every position belongs to the launchpad's locker, which never releases
  # them and forwards the fees it collects to the launch's splitter. Each
  # carries what a collection would deposit right now, simulated on the locker.
  defp positions(config, launch, stock, current, block, opts) do
    manager = Lab.address!(config, :position_manager)
    locker = launch.contracts.locker

    full_range = %{
      key: :full_range,
      label: "Full range",
      token_id: launch.lp_token_id,
      token_amount: Rpc.format_units(launch.lp_new_used, @token_decimals),
      currency_amount: Rpc.format_units(launch.lp_stock_used, stock.decimals)
    }

    held =
      case launch.second do
        %{key: :stock_only, token_id: token_id, used: used} when token_id != 0 ->
          [full_range, Pool.stock_only_position(token_id, used, stock.decimals)]

        %{key: :new_only, token_id: token_id, used: used} when token_id != 0 ->
          [full_range, Pool.new_only_position(token_id, used)]

        _none ->
          [full_range]
      end

    token_is_currency0? = currency0?(launch.new_token, launch.stock)

    Enum.reduce_while(held, {:ok, []}, fn position, {:ok, found} ->
      with {:ok, owner} <- owner_of(manager, position.token_id, block, opts),
           {:ok, range} <- PoolRange.read(manager, position.token_id, block, opts) do
        held =
          Map.merge(position, %{
            owner: owner,
            locked?: Address.equal?(owner, locker),
            range: range,
            holds: Pool.holdings(range, current, token_is_currency0?, stock.decimals),
            uncollected: uncollected(launch, position.token_id, stock, block, opts)
          })

        {:cont, {:ok, found ++ [held]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # `collect` simulated through `eth_call`: the fees a collection would deposit
  # into the splitter now, or nil when the simulation cannot answer.
  defp uncollected(launch, token_id, stock, block, opts) do
    %{locker: locker, abis: %{"locker" => abi}} = launch.contracts
    data = LabAbi.encode(abi, "collect(uint256)", [token_id])

    case Rpc.call_words(locker, data, block, 2, opts) do
      {:ok, [amount0, amount1]} ->
        {token, currency} =
          if currency0?(launch.new_token, launch.stock),
            do: {amount0, amount1},
            else: {amount1, amount0}

        %{
          token_amount: Rpc.format_units(token, @token_decimals),
          currency_amount: Rpc.format_units(currency, stock.decimals)
        }

      {:error, _reason} ->
        nil
    end
  end

  # The hook's lanes for this pool, read from its own storage right now, every
  # fee it charged the pool's trades and every lane it settled, the wallet the
  # Safe named to convert Regent's lane, and the splitter the staker lane and
  # the locker's LP fees flow to. Like the price history, the hook's logs are
  # read from the chain's start.
  defp fees(config, launch, stock, block, opts) do
    %{hook: hook, abis: %{"hook" => abi}} = contracts = launch.contracts

    with {:ok, figures} <-
           Pool.lanes(contracts, launch.pool_id, stock.decimals, @usdg_decimals, block, opts),
         {:ok, converter} <-
           Rpc.call_address(hook, LabAbi.encode(abi, "executor()", []), block, opts),
         {:ok, splitter} <- splitter_facts(config, launch.splitter, block, opts),
         {:ok, logs} <- hook_logs(contracts, launch.pool_id, block, opts) do
      accrued_topic = LabAbi.topic(contracts.fee_accrued)
      settled_topics = Map.new(contracts.lane_settled, &{LabAbi.topic(elem(&1, 1)), elem(&1, 0)})
      accrued_logs = Enum.filter(logs, &(event_topic(&1) == accrued_topic))

      {:ok,
       figures
       |> put_in([:regent, :converter], converter)
       |> Map.merge(%{
         charged: Enum.map(accrued_logs, &Pool.charged/1),
         splitter: splitter,
         settlements:
           for(
             log <- logs,
             {:ok, lane} <- [Map.fetch(settled_topics, event_topic(log))],
             do: Pool.settlement(log, lane, stock.decimals)
           )
       })}
    end
  end

  # The memestock splitter of a graduated launch: what is staked in it, the
  # skim it keeps from every unstake, and the dollar it pays out in.
  defp splitter_facts(config, splitter, block, opts) do
    abi = Lab.abi!(config, :splitter)

    with {:ok, total_staked} <-
           Rpc.call_uint(splitter, LabAbi.encode(abi, "totalStaked()", []), block, opts),
         {:ok, skim_bps} <-
           Rpc.call_uint(splitter, LabAbi.encode(abi, "SKIM_BPS()", []), block, opts),
         {:ok, dollar} <-
           Rpc.call_address(splitter, LabAbi.encode(abi, "dollar()", []), block, opts) do
      {:ok,
       %{
         address: splitter,
         total_staked: Rpc.format_units(total_staked, @token_decimals),
         total_staked_atomic: total_staked,
         skim_bps: skim_bps,
         dollar: %{address: dollar, symbol: "USDG", decimals: @usdg_decimals}
       }}
    end
  end

  defp hook_logs(contracts, pool_id, block, opts) do
    filter = %{
      address: contracts.hook,
      fromBlock: "0x0",
      toBlock: "0x" <> Integer.to_string(block.number, 16),
      topics: [nil, pool_id]
    }

    case Rpc.request("eth_getLogs", [filter], opts) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:ok, _other} -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  defp event_topic(%{"topics" => [topic | _rest]}), do: String.downcase(topic)

  defp owner_of(position_manager, token_id, block, opts) do
    Rpc.call_address(
      position_manager,
      @owner_of_selector <> (token_id |> Integer.to_string(16) |> String.pad_leading(64, "0")),
      block,
      opts
    )
  end

  defp launchpad_uint(contracts, signature, arguments, block, opts) do
    Rpc.call_uint(
      contracts.launchpad,
      LabAbi.encode(contracts.abis["launchpad"], signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_words(contracts, signature, arguments, count, block, opts) do
    Rpc.call_words(
      contracts.launchpad,
      LabAbi.encode(contracts.abis["launchpad"], signature, arguments),
      block,
      count,
      opts
    )
  end

  defp currency0?(token, currency) do
    {:ok, token_bytes} = Address.decode(token)
    {:ok, currency_bytes} = Address.decode(currency)
    token_bytes < currency_bytes
  end

  defp bytes32(value) when is_integer(value),
    do:
      "0x" <> (value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))
end
