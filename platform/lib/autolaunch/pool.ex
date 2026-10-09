defmodule Autolaunch.Pool do
  @moduledoc """
  Read-only pool facts for one graduated launch, read from Base.

  Agent launches graduate into a REGENT/SUBJECT pool recorded by the frozen
  strategy (`distribution(auction)`), charged by the frozen `RegentFeeHook`,
  whose splitter lane lands in the launch's revenue splitter on every trade,
  and locked in the strategy's `RevstakeLPLocker`, whose collected fees flow to
  that same splitter; Stocks launches graduate into a NEW/STOCK pool recorded
  by the launchpad (`launches(id)`), charged by `StocksFeeHookV1` and locked in
  the launchpad's LP locker, whose fees flow to the launch's memestake
  splitter. Both are read at one latest block: the pool key and id, the price
  at graduation, the current pool price and liquidity from the PoolManager's
  own storage, the locked positions with their owner and the fees a collection
  would deposit now, the unsold tokens' fate, and the fee lanes with their
  totals.

  Nothing here writes, signs or caches; every figure is the chain's own answer.
  """

  alias Autolaunch.Chain.{Abi, Rpc}

  alias Autolaunch.{Lab, LabAbi, LabRpc, PoolPrice, PoolRange, PriceHistory, RewardHistory}
  alias Autolaunch.Stocks.FeeSchedule
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias RegentChain.Address

  @dead "0x000000000000000000000000000000000000dead"
  @token_decimals 18
  @regent_decimals 18
  @usdc_decimals 6
  @staker_lane_bps 200
  @pools_slot 6
  @liquidity_offset 3
  @quote_fraction_digits 18
  @uniswap_pool_url "https://app.uniswap.org/explore/pools/base/"

  # Concrete-contract reads the pinned interface ABIs do not carry: fixed
  # selectors for `extsload(bytes32)` and `ownerOf(uint256)`.
  @extsload_selector "0x1e2eaeaf"
  @owner_of_selector "0x6352211e"

  @type t :: map()

  @doc "The lab's pool facts for one graduated auction row, or why they cannot be read."
  @spec read(map()) :: {:ok, t()} | {:error, atom()}
  def read(%{state: state}) when state != :graduated, do: {:error, :not_graduated}

  def read(%{kind: :agent} = auction) do
    with {:ok, config} <- Lab.current(),
         opts <- LabRpc.opts(config, "autolaunch pool page"),
         {:ok, block} <- Rpc.latest_block(opts),
         do: read_agent(auction, config, block, opts)
  end

  def read(%{kind: :stocks} = auction) do
    with {:ok, config} <- StocksLab.current(),
         opts <- StocksLab.rpc_opts(config, "autolaunch pool page"),
         {:ok, block} <- Rpc.latest_block(opts),
         do: read_stocks(auction, config, block, opts)
  end

  @doc """
  The same facts at a block already read, on the deployment it was read with:
  for a page that reads several pools at one moment.
  """
  @spec read_at(map(), map(), Rpc.block(), keyword()) :: {:ok, t()} | {:error, atom()}
  def read_at(%{state: state}, _config, _block, _opts) when state != :graduated,
    do: {:error, :not_graduated}

  def read_at(%{kind: :agent} = auction, config, block, opts),
    do: read_agent(auction, config, block, opts)

  def read_at(%{kind: :stocks} = auction, config, block, opts),
    do: read_stocks(auction, config, block, opts)

  @doc """
  The pool's current price for the token record, from the words a market feed
  already read: an agent launch's `distribution`, or a Stocks launch's
  `launches` record with its stock's decimals. `nil` until the launch has a
  pool with a price. The figure is the currency per whole token as a plain
  decimal cut at eighteen fraction places, never rounded up, so it fits the
  record and shortens on screen; every digit stays readable on the pool page.
  """
  @spec agent_price_quote(map(), [non_neg_integer()], Rpc.block(), keyword()) ::
          {:ok, String.t() | nil} | {:error, atom()}
  def agent_price_quote(config, words, block, opts) do
    case agent_distribution(words) do
      {:ok, distribution} ->
        price_quote(
          Lab.address!(config, :pool_manager),
          distribution.pool_id,
          currency0?(distribution.subject, Lab.address!(config, :regent)),
          @regent_decimals,
          block,
          opts
        )

      {:error, :not_graduated} ->
        {:ok, nil}

      error ->
        error
    end
  end

  @spec stocks_price_quote(map(), map(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, String.t() | nil} | {:error, atom()}
  def stocks_price_quote(config, record, currency_decimals, block, opts) do
    case stocks_launch(record) do
      {:ok, launch} ->
        pool_price_quote(
          %{
            pool_manager: StocksLab.address!(config, :pool_manager),
            pool_id: launch.pool_id,
            token: launch.new_token,
            currency: launch.stock,
            currency_decimals: currency_decimals
          },
          block,
          opts
        )

      {:error, :not_graduated} ->
        {:ok, nil}

      error ->
        error
    end
  end

  @doc """
  A Memestake pool's current price, in its stock per launched token, from the
  pool manager's slot0 at a pinned block: the Base Memestake and Robinhood
  launchpads' pools are both Uniswap v4 pools of an 18-decimal token and its stock.
  """
  @spec pool_price_quote(map(), Rpc.block(), keyword()) ::
          {:ok, String.t() | nil} | {:error, atom()}
  def pool_price_quote(pool, block, opts) do
    price_quote(
      pool.pool_manager,
      pool.pool_id,
      currency0?(pool.token, pool.currency),
      pool.currency_decimals,
      block,
      opts
    )
  end

  defp price_quote(pool_manager, pool_id, token_is_currency0?, decimals, block, opts) do
    with {:ok, [slot0]} <- extsload(pool_manager, state_slot(pool_id), block, opts) do
      sqrt_price = rem(slot0, Integer.pow(2, 160))

      case PoolPrice.currency_per_token(
             sqrt_price,
             token_is_currency0?,
             @token_decimals,
             decimals
           ) do
        {:ok, price} -> {:ok, cut(price.value)}
        {:error, :invalid_sqrt_price} -> {:ok, nil}
      end
    end
  end

  defp cut(value) do
    case String.split(String.trim_trailing(value, "…"), ".", parts: 2) do
      [whole] ->
        whole

      [whole, fraction] ->
        case fraction |> String.slice(0, @quote_fraction_digits) |> String.trim_trailing("0") do
          "" -> whole
          kept -> whole <> "." <> kept
        end
    end
  end

  @doc "The public Base pool page on the Uniswap app for a pool id."
  def uniswap_url(pool_id), do: @uniswap_pool_url <> pool_id

  def dead_address, do: @dead

  @doc """
  The graduated token's contract, for reads that need nothing else from the
  pool: the strategy's `distribution` names it for an agent launch, the
  launchpad's `launches` record for a Stocks launch.
  """
  @spec token_address(map(), map(), Rpc.block(), keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def token_address(%{kind: :agent} = auction, config, block, opts) do
    with {:ok, distribution} <- agent_record(auction, config, block, opts),
         do: {:ok, distribution.subject}
  end

  def token_address(%{kind: :stocks} = auction, config, block, opts) do
    with {:ok, launch} <- stocks_record(auction, config, block, opts),
         do: {:ok, launch.new_token}
  end

  @doc """
  What a reader of the pool's trades needs: the PoolManager, the pool id, the
  token, which side of the pool it is on, the currency it trades against and
  the block the pool opened in. `{:error, :not_graduated}` until the pool
  exists.
  """
  @spec swap_source(map(), map(), Rpc.block(), keyword()) :: {:ok, map()} | {:error, atom()}
  def swap_source(%{kind: :agent} = auction, config, block, opts) do
    with {:ok, distribution} <- agent_record(auction, config, block, opts) do
      {:ok,
       %{
         pool_manager: Lab.address!(config, :pool_manager),
         pool_id: distribution.pool_id,
         token: distribution.subject,
         token_is_currency0?: currency0?(distribution.subject, Lab.address!(config, :regent)),
         currency_symbol: "REGENT",
         currency_decimals: @regent_decimals,
         from_block: distribution.migration_block
       }}
    end
  end

  def swap_source(%{kind: :stocks} = auction, config, block, opts) do
    with {:ok, launch} <- stocks_record(auction, config, block, opts) do
      {:ok,
       %{
         pool_manager: StocksLab.address!(config, :pool_manager),
         pool_id: launch.pool_id,
         token: launch.new_token,
         token_is_currency0?: currency0?(launch.new_token, launch.stock),
         currency_symbol: auction.quote_token_symbol,
         currency_decimals: auction.quote_token_decimals,
         from_block: launch.migration_block
       }}
    end
  end

  defp agent_record(auction, config, block, opts) do
    with {:ok, words} <-
           LabRpc.words(
             config,
             :strategy,
             "distribution(address)",
             [auction.auction_address],
             LabAbi.distribution_words(),
             block,
             opts
           ),
         do: agent_distribution(words)
  end

  # A launch reads only the launchpad, hook and locker of its own version.
  defp stocks_record(auction, config, block, opts) do
    with {:ok, contracts} <- StocksLab.contracts(config, auction.contracts_version),
         {:ok, launch_id} <-
           launchpad_uint(
             contracts,
             "launchIdOfAuction(address)",
             [auction.auction_address],
             block,
             opts
           ),
         {:ok, words} <-
           launchpad_words(
             contracts,
             "launches(uint256)",
             [launch_id],
             contracts.record_words,
             block,
             opts
           ),
         record <- StocksLabAbi.record(contracts, words),
         {:ok, launch} <- stocks_launch(record),
         {:ok, vesting} <- creator_vesting(contracts, record, launch_id, block, opts) do
      {:ok,
       Map.merge(launch, %{
         launch_id: launch_id,
         contracts: contracts,
         second: second_position(contracts.version, record),
         vesting: vesting
       })}
    end
  end

  # The second launchpad vests 0.5% of each launch's supply to its creator.
  defp creator_vesting(%{version: :v1}, _record, _launch_id, _block, _opts), do: {:ok, nil}

  defp creator_vesting(%{version: :v2} = contracts, record, launch_id, block, opts) do
    with {:ok, releasable} <-
           launchpad_uint(contracts, "creatorReleasable(uint256)", [launch_id], block, opts),
         do: vesting(record, releasable)
  end

  @doc """
  A launch's creator vesting as a pool shows it: the creator it pays, what
  has been released and what anyone can release to the creator now.
  """
  def vesting(record, releasable) do
    with {:ok, creator} <- Abi.word_address(record.launcher) do
      {:ok,
       %{
         creator: creator,
         released: Rpc.format_units(record.creator_released, @token_decimals),
         releasable: Rpc.format_units(releasable, @token_decimals)
       }}
    end
  end

  # Beside the full-range position, the first launchpad keeps a stock-only
  # position and the second a new-token-only one above the opening price.
  defp second_position(:v1, record),
    do: %{key: :stock_only, token_id: record.stock_only_token_id, used: record.stock_only_used}

  defp second_position(:v2, record),
    do: %{key: :new_only, token_id: record.new_only_token_id, used: record.new_only_used}

  # Agent

  defp read_agent(auction, config, block, opts) do
    with {:ok, distribution} <- agent_record(auction, config, block, opts),
         {:ok, fee} <- LabRpc.uint(config, :strategy, "POOL_FEE()", [], block, opts),
         {:ok, spacing} <- LabRpc.uint(config, :strategy, "POOL_TICK_SPACING()", [], block, opts),
         {:ok, unsold} <-
           LabRpc.call_uint(
             config,
             auction.auction_address,
             "auction",
             "remainingSupply()",
             [],
             block,
             opts
           ),
         regent <- Lab.address!(config, :regent),
         token_is_currency0? <- currency0?(distribution.subject, regent),
         {:ok, graduation_price} <-
           PoolPrice.currency_per_token(
             distribution.final_sqrt_price_x96,
             token_is_currency0?,
             @token_decimals,
             @regent_decimals
           ),
         {:ok, current} <-
           pool_state(
             Lab.address!(config, :pool_manager),
             distribution.pool_id,
             token_is_currency0?,
             @token_decimals,
             @regent_decimals,
             block,
             opts
           ),
         locker <- Lab.address!(config, :lp_locker),
         {:ok, owner} <-
           owner_of(
             Lab.address!(config, :position_manager),
             distribution.lp_token_id,
             block,
             opts
           ),
         {:ok, range} <-
           PoolRange.read(
             Lab.address!(config, :position_manager),
             distribution.lp_token_id,
             block,
             opts
           ),
         {:ok, fees} <-
           agent_fees(config, distribution, auction, block, opts),
         {:ok, rewards} <-
           RewardHistory.recognized(
             :revstake,
             distribution.splitter,
             distribution.migration_block,
             block,
             opts
           ),
         {:ok, treasury_vesting} <- treasury_vesting(config, distribution, block, opts),
         {:ok, prices} <-
           PriceHistory.pool(
             %{
               pool_manager: Lab.address!(config, :pool_manager),
               pool_id: distribution.pool_id,
               token_is_currency0?: token_is_currency0?,
               currency_decimals: @regent_decimals
             },
             distribution.migration_block,
             block,
             opts
           ) do
      {:ok,
       %{
         kind: :agent,
         chain: :base,
         block: block,
         pool_id: distribution.pool_id,
         token: %{
           address: distribution.subject,
           symbol: auction.token_symbol,
           decimals: @token_decimals
         },
         currency: %{address: regent, symbol: "REGENT", decimals: @regent_decimals},
         token_is_currency0?: token_is_currency0?,
         lp_fee: percent(fee),
         pool_fee: fee,
         tick_spacing: spacing,
         hook: Lab.address!(config, :hook),
         locker: locker,
         pool_manager: Lab.address!(config, :pool_manager),
         logs_from: distribution.migration_block,
         graduation_price: graduation_price,
         current: current,
         prices: prices,
         positions: [
           %{
             key: :full_range,
             label: "Full range",
             token_id: distribution.lp_token_id,
             owner: owner,
             locked?: Address.equal?(owner, locker),
             token_amount: Rpc.format_units(distribution.lp_subject_used, @token_decimals),
             currency_amount: Rpc.format_units(distribution.lp_regent_used, @regent_decimals),
             range: range,
             holds: holdings(range, current, token_is_currency0?, @regent_decimals),
             uncollected:
               uncollected(
                 locker,
                 Lab.abi!(config, :lp_locker),
                 distribution.lp_token_id,
                 token_is_currency0?,
                 @regent_decimals,
                 block,
                 opts
               )
           }
         ],
         unsold: %{
           amount: Rpc.format_units(unsold, @token_decimals),
           disposition: :escrow,
           address: distribution.escrow
         },
         uniswap_url: uniswap_url(distribution.pool_id),
         fees: fees,
         rewards: rewards,
         treasury_vesting: treasury_vesting
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # The pool id is read first: until the strategy migrates the launch, the
  # splitter and receiver words are still zero and decode as no address.
  defp agent_distribution(words) do
    distribution = LabAbi.distribution(words)

    with pool_id when pool_id != 0 <- distribution.pool_id,
         {:ok, subject} <- Abi.word_address(distribution.subject),
         {:ok, escrow} <- Abi.word_address(distribution.escrow),
         {:ok, splitter} <- Abi.word_address(distribution.splitter),
         {:ok, receiver} <- Abi.word_address(distribution.receiver) do
      {:ok,
       %{
         migration_block: distribution.migration_block,
         lp_regent_used: distribution.lp_regent_used,
         lp_subject_used: distribution.lp_subject_used,
         final_sqrt_price_x96: distribution.final_sqrt_price_x96,
         subject: subject,
         escrow: escrow,
         splitter: splitter,
         receiver: receiver,
         pool_id: bytes32(pool_id),
         lp_token_id: distribution.lp_token_id
       }}
    else
      0 -> {:error, :not_graduated}
      :error -> {:error, :invalid_chain_response}
    end
  end

  # Every `SwapFeeSettled` this pool emitted since graduation, the staker lane
  # summed per fee token. A swap is charged both lanes: 1% to Regent and 2% to
  # the launch's stakers.
  # The splitter's lane lands in it on the trade itself; the locked position's
  # own pool fees wait in the position until collected, and the position
  # carries what a collection would deposit now.
  defp agent_fees(config, distribution, auction, block, opts) do
    hook = Lab.address!(config, :hook)

    with {:ok, logs} <-
           logs(hook, distribution.migration_block, block, [nil, distribution.pool_id], opts),
         {:ok, splitter} <-
           splitter_facts(
             Lab.abi!(config, :splitter),
             "usdc()",
             distribution.splitter,
             block,
             opts
           ) do
      topic = LabAbi.topic(LabAbi.swap_fee_settled_signature())

      settled =
        logs
        |> Enum.filter(&(topic_at(&1, 0) == topic))
        |> Enum.map(fn log ->
          {:ok, fee_token} = log |> topic_at(3) |> word() |> Abi.word_address()
          [_fee_base, regent_lane, lane, _exact_input] = data_words(log)
          {String.downcase(fee_token), lane, regent_lane + lane, quantity(log["blockNumber"])}
        end)

      per_token =
        Enum.reduce(settled, %{}, fn {token, lane, _charged, _block}, sums ->
          Map.update(sums, token, lane, &(&1 + lane))
        end)

      regent = Lab.address!(config, :regent)
      regent_fee? = &(&1 == String.downcase(regent))

      {:ok,
       %{
         lane_bps: @staker_lane_bps,
         splitter: splitter,
         receiver: distribution.receiver,
         swaps: length(settled),
         per_lane: %{
           currency:
             Rpc.format_units(Map.get(per_token, String.downcase(regent), 0), @regent_decimals),
           token:
             Rpc.format_units(
               Map.get(per_token, String.downcase(distribution.subject), 0),
               @token_decimals
             )
         },
         token_symbol: auction.token_symbol,
         charged:
           for {token, _lane, charged, block} <- settled do
             if regent_fee?.(token),
               do: %{block: block, currency: charged, token: 0},
               else: %{block: block, currency: 0, token: charged}
           end
       }}
    end
  end

  # The vesting escrow that holds the treasury's tokens and releases them to
  # it over a year from graduation. Read the way its own `release()` works:
  # everything it has held is the escrow's balance plus what it has released,
  # and the part vested so far grows in a straight line from `vestingStart`.
  defp treasury_vesting(config, distribution, block, opts) do
    escrow = distribution.escrow
    read = &LabRpc.call_uint(config, escrow, "escrow", &1, [], block, opts)

    with {:ok, lifecycle} <- read.("lifecycle()"),
         {:ok, start} <- read.("vestingStart()"),
         {:ok, duration} <- read.("VESTING_DURATION()"),
         {:ok, released} <- read.("totalReleased()"),
         {:ok, held} <-
           Rpc.call_uint(
             distribution.subject,
             Abi.encode_erc20("balance_of", [escrow]),
             block,
             opts
           ) do
      {:ok, vesting_schedule(lifecycle, start, duration, released, held, block.timestamp, escrow)}
    end
  end

  @doc """
  A treasury escrow's schedule at `now`: released, ready to release and still
  locked, in atomic units and whole tokens, with the year it vests over.
  `lifecycle` is the escrow's own: 0 waiting for the auction, 1 graduated
  and 2 failed.
  """
  def vesting_schedule(lifecycle, start, duration, released, held, now, escrow) do
    total = held + released

    vested =
      case lifecycle do
        1 -> div(total * min(max(now - start, 0), duration), duration)
        _other -> released
      end

    %{
      state: Enum.at([:pending, :graduated, :failed], lifecycle),
      address: escrow,
      starts_at: start,
      ends_at: start + duration,
      now: now,
      total: total,
      released: released,
      releasable: vested - released,
      locked: total - vested,
      decimals: @token_decimals
    }
  end

  # Stocks

  defp read_stocks(auction, config, block, opts) do
    with {:ok, launch} <- stocks_record(auction, config, block, opts),
         decimals <- auction.quote_token_decimals,
         token_is_currency0? <- currency0?(launch.new_token, launch.stock),
         {:ok, graduation_price} <-
           PoolPrice.currency_per_token(
             launch.final_sqrt_price_x96,
             token_is_currency0?,
             @token_decimals,
             decimals
           ),
         {:ok, current} <-
           pool_state(
             StocksLab.address!(config, :pool_manager),
             launch.pool_id,
             token_is_currency0?,
             @token_decimals,
             decimals,
             block,
             opts
           ),
         {:ok, positions} <- stocks_positions(config, launch, current, decimals, block, opts),
         {:ok, fees} <- stocks_fees(config, launch, decimals, block, opts),
         {:ok, rewards} <-
           RewardHistory.recognized(
             :memestake,
             launch.splitter,
             launch.migration_block,
             block,
             opts
           ),
         {:ok, prices} <-
           PriceHistory.pool(
             %{
               pool_manager: StocksLab.address!(config, :pool_manager),
               pool_id: launch.pool_id,
               token_is_currency0?: token_is_currency0?,
               currency_decimals: decimals
             },
             launch.migration_block,
             block,
             opts
           ) do
      {:ok,
       %{
         kind: :stocks,
         chain: :base,
         block: block,
         launch_id: launch.launch_id,
         pool_id: launch.pool_id,
         token: %{
           address: launch.new_token,
           symbol: auction.token_symbol,
           decimals: @token_decimals
         },
         currency: %{
           address: launch.stock,
           symbol: auction.quote_token_symbol,
           decimals: decimals
         },
         token_is_currency0?: token_is_currency0?,
         lp_fee: FeeSchedule.lane(:base, launch.contracts.version, :pool).rate,
         pool_fee: FeeSchedule.pool_fee(:base, launch.contracts.version),
         tick_spacing: 60,
         version: launch.contracts.version,
         launchpad: launch.contracts.launchpad,
         hook: launch.contracts.hook,
         locker: launch.contracts.locker,
         pool_manager: StocksLab.address!(config, :pool_manager),
         logs_from: launch.migration_block,
         graduation_price: graduation_price,
         current: current,
         prices: prices,
         positions: positions,
         unsold: %{
           amount: Rpc.format_units(launch.retired_new, @token_decimals),
           disposition: :retired,
           address: @dead
         },
         uniswap_url: uniswap_url(launch.pool_id),
         fees: fees,
         rewards: rewards,
         vesting: launch.vesting
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # A launch that has not graduated has no splitter or pool yet, so its record
  # is read only once its lifecycle says the pool exists.
  defp stocks_launch(record) do
    with 2 <- record.lifecycle,
         {:ok, new_token} <- Abi.word_address(record.new_token),
         {:ok, stock} <- Abi.word_address(record.stock),
         {:ok, splitter} <- Abi.word_address(record.splitter) do
      {:ok,
       %{
         new_token: new_token,
         stock: stock,
         splitter: splitter,
         migration_block: record.migration_block,
         pool_id: bytes32(record.pool_id),
         final_sqrt_price_x96: record.final_sqrt_price_x96,
         lp_token_id: record.lp_token_id,
         lp_stock_used: record.lp_stock_used,
         lp_new_used: record.lp_new_used,
         retired_new: record.retired_new
       }}
    else
      :error -> {:error, :invalid_chain_response}
      _lifecycle -> {:error, :not_graduated}
    end
  end

  # Every position belongs to the launchpad's locker, which never releases
  # them and forwards the fees it collects to the launch's splitter. Each
  # carries what a collection would deposit right now, simulated on the locker.
  defp stocks_positions(config, launch, current, decimals, block, opts) do
    manager = StocksLab.address!(config, :position_manager)
    %{locker: locker, abis: %{"locker" => abi}} = launch.contracts
    token_is_currency0? = currency0?(launch.new_token, launch.stock)

    launch
    |> held_positions(decimals)
    |> Enum.reduce_while({:ok, []}, fn position, {:ok, found} ->
      with {:ok, owner} <- owner_of(manager, position.token_id, block, opts),
           {:ok, range} <- PoolRange.read(manager, position.token_id, block, opts) do
        held =
          Map.merge(position, %{
            owner: owner,
            locked?: Address.equal?(owner, locker),
            range: range,
            holds: holdings(range, current, token_is_currency0?, decimals),
            uncollected:
              uncollected(
                locker,
                abi,
                position.token_id,
                token_is_currency0?,
                decimals,
                block,
                opts
              )
          })

        {:cont, {:ok, found ++ [held]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # The full-range position, and beside it the launch's second position when
  # it made one.
  defp held_positions(launch, decimals) do
    full_range = %{
      key: :full_range,
      label: "Full range",
      token_id: launch.lp_token_id,
      token_amount: Rpc.format_units(launch.lp_new_used, @token_decimals),
      currency_amount: Rpc.format_units(launch.lp_stock_used, decimals)
    }

    case launch.second do
      %{key: :stock_only, token_id: token_id, used: used} when token_id != 0 ->
        [full_range, stock_only_position(token_id, used, decimals)]

      %{key: :new_only, token_id: token_id, used: used} when token_id != 0 ->
        [full_range, new_only_position(token_id, used)]

      _none ->
        [full_range]
    end
  end

  @doc """
  What a locked position holds at the pool's current price, worked out from
  its range and liquidity, and whether that price is inside its range. Nil
  when the pool's price could not be read.
  """
  def holdings(_range, nil, _token_is_currency0?, _currency_decimals), do: nil

  def holdings(range, current, token_is_currency0?, currency_decimals) do
    {amount0, amount1} = PoolRange.amounts(range, current.sqrt_price_x96)
    {token, currency} = if token_is_currency0?, do: {amount0, amount1}, else: {amount1, amount0}

    %{
      token_amount: Rpc.format_units(token, @token_decimals),
      currency_amount: Rpc.format_units(currency, currency_decimals),
      in_range?: PoolRange.in_range?(range, current.tick)
    }
  end

  @doc "A launch's new-token-only position above the opening price, as a pool's positions list it."
  def new_only_position(token_id, used),
    do: %{
      key: :new_only,
      label: "One-sided (token only)",
      token_id: token_id,
      token_amount: Rpc.format_units(used, @token_decimals),
      currency_amount: "0"
    }

  @doc "The first launchpad's stock-only position, as a pool's positions list it."
  def stock_only_position(token_id, used, decimals),
    do: %{
      key: :stock_only,
      label: "One-sided (currency only)",
      token_id: token_id,
      token_amount: "0",
      currency_amount: Rpc.format_units(used, decimals)
    }

  # The hook's lanes for this pool, read from its own storage right now, plus
  # every accrual and settlement it emitted since graduation, the wallet the
  # Safe named to convert Regent's lane, and the splitter the staker lane and
  # the locker's LP fees flow to.
  defp stocks_fees(config, launch, decimals, block, opts) do
    %{hook: hook, abis: %{"hook" => abi}} = contracts = launch.contracts

    with {:ok, figures} <-
           lanes(contracts, launch.pool_id, decimals, @usdc_decimals, block, opts),
         {:ok, converter} <-
           Rpc.call_address(hook, LabAbi.encode(abi, "executor()", []), block, opts),
         {:ok, splitter} <-
           splitter_facts(
             StocksLab.abi!(config, :splitter),
             "dollar()",
             launch.splitter,
             block,
             opts
           ),
         {:ok, logs} <- logs(hook, launch.migration_block, block, [nil, launch.pool_id], opts) do
      accrued_topic = LabAbi.topic(contracts.fee_accrued)
      settled_topics = Map.new(contracts.lane_settled, &{LabAbi.topic(elem(&1, 1)), elem(&1, 0)})
      accrued_logs = Enum.filter(logs, &(topic_at(&1, 0) == accrued_topic))

      {:ok,
       figures
       |> put_in([:regent, :converter], converter)
       |> Map.merge(%{
         trades: length(accrued_logs),
         charged: Enum.map(accrued_logs, &charged/1),
         splitter: splitter,
         settlements:
           for(
             log <- logs,
             {:ok, lane} <- [Map.fetch(settled_topics, topic_at(log, 0))],
             do: settlement(log, lane, decimals)
           )
       })}
    end
  end

  @doc """
  A memestock hook's lanes for one pool, read from its `accrued` and `settled`
  answers at `block` and keyed by lane as `lane_figures/5` gives them.
  `contracts` is the launch's hook, its ABI and its lane order.
  """
  @spec lanes(map(), String.t(), non_neg_integer(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def lanes(
        %{hook: hook, abis: %{"hook" => abi}, lanes: lanes},
        pool_id,
        decimals,
        dollar_decimals,
        block,
        opts
      ) do
    with {:ok, accrued} <-
           Rpc.call_words(
             hook,
             LabAbi.encode(abi, "accrued(bytes32)", [pool_id]),
             block,
             length(lanes),
             opts
           ),
         {:ok, settled} <-
           Rpc.call_words(
             hook,
             LabAbi.encode(abi, "settled(bytes32)", [pool_id]),
             block,
             length(lanes) + 1,
             opts
           ),
         do: {:ok, lane_figures(lanes, accrued, settled, decimals, dollar_decimals)}
  end

  @doc """
  The REGENT lane of one graduated Base memestock launch at `block`: the
  stock it trades against and the lane's figures, atomic amounts included.
  """
  @spec regent_lane(map(), map(), Rpc.block(), keyword()) :: {:ok, map()} | {:error, atom()}
  def regent_lane(auction, config, block, opts) do
    decimals = auction.quote_token_decimals

    with {:ok, launch} <- stocks_record(auction, config, block, opts),
         {:ok, %{regent: regent}} <-
           lanes(launch.contracts, launch.pool_id, decimals, @usdc_decimals, block, opts) do
      {:ok,
       Map.put(regent, :stock, %{
         address: String.downcase(launch.stock),
         symbol: auction.quote_token_symbol,
         decimals: decimals
       })}
    end
  end

  @doc """
  A memestock hook's lanes for one pool, keyed by lane, from its `accrued` and
  `settled` answers: what each lane holds now and what it has paid out.
  `settled` gives one figure per lane in `accrued`'s order, and two for
  REGENT's lane: the stock it converted and the dollars that brought.
  """
  def lane_figures(lanes, accrued, settled, decimals, dollar_decimals) do
    {figures, []} =
      lanes
      |> Enum.zip(accrued)
      |> Enum.map_reduce(settled, fn
        {:regent, held}, [converted, deposited | rest] ->
          {{:regent,
            %{
              accrued: Rpc.format_units(held, decimals),
              accrued_atomic: held,
              settled_currency: Rpc.format_units(converted, decimals),
              settled_currency_atomic: converted,
              settled_usdc: Rpc.format_units(deposited, dollar_decimals),
              settled_usdc_atomic: deposited
            }}, rest}

        {lane, held}, [paid | rest] ->
          {{lane,
            %{
              accrued: Rpc.format_units(held, decimals),
              accrued_atomic: held,
              settled_currency: Rpc.format_units(paid, decimals)
            }}, rest}
      end)

    Map.new(figures)
  end

  # The memestake splitter of a graduated launch: what is staked in it, the
  # skim it keeps from every unstake, and the dollar it pays out in.
  # A launch's splitter as the staking card shows it. Both splitters name
  # their dollar asset, the Revstake one as `usdc()` and the memestock one as
  # `dollar()`; it is USDC on either.
  defp splitter_facts(abi, dollar_signature, splitter, block, opts) do
    with {:ok, total_staked} <-
           Rpc.call_uint(splitter, LabAbi.encode(abi, "totalStaked()", []), block, opts),
         {:ok, skim_bps} <-
           Rpc.call_uint(splitter, LabAbi.encode(abi, "SKIM_BPS()", []), block, opts),
         {:ok, dollar} <-
           Rpc.call_address(splitter, LabAbi.encode(abi, dollar_signature, []), block, opts) do
      {:ok,
       %{
         address: splitter,
         total_staked: Rpc.format_units(total_staked, @token_decimals),
         total_staked_atomic: total_staked,
         skim_bps: skim_bps,
         dollar: %{address: dollar, symbol: "USDC", decimals: @usdc_decimals}
       }}
    end
  end

  @doc """
  One trade's fee from a memestock hook's `HookFeeAccrued` log, on Base or
  Robinhood: every lane after the fee base, in atomic units of the pool's
  currency.
  """
  def charged(log) do
    [_fee_base | lanes] = data_words(log)
    %{block: quantity(log["blockNumber"]), currency: Enum.sum(lanes), token: 0}
  end

  @doc """
  One lane settlement from a memestock hook's log, on Base or Robinhood: the
  amount sent on, and for Regent's lane the dollars its conversion brought,
  with the block and transaction it happened in.
  """
  def settlement(log, :regent, decimals) do
    [stock_converted, usdc_deposited] = data_words(log)

    %{
      lane: :regent,
      currency: Rpc.format_units(stock_converted, decimals),
      usdc: Rpc.format_units(usdc_deposited, @usdc_decimals),
      block: quantity(log["blockNumber"]),
      transaction_hash: log["transactionHash"]
    }
  end

  def settlement(log, lane, decimals) do
    [amount] = data_words(log)

    %{
      lane: lane,
      currency: Rpc.format_units(amount, decimals),
      usdc: nil,
      block: quantity(log["blockNumber"]),
      transaction_hash: log["transactionHash"]
    }
  end

  # Shared chain reads

  # `collect` simulated through `eth_call` on the locker that owns the
  # position: the fees a collection would deposit into the splitter now, or
  # nil when the simulation cannot answer.
  defp uncollected(locker, abi, token_id, token_is_currency0?, decimals, block, opts) do
    data = LabAbi.encode(abi, "collect(uint256)", [token_id])

    case Rpc.call_words(locker, data, block, 2, opts) do
      {:ok, [amount0, amount1]} ->
        {token, currency} =
          if token_is_currency0?, do: {amount0, amount1}, else: {amount1, amount0}

        %{
          token_amount: Rpc.format_units(token, @token_decimals),
          currency_amount: Rpc.format_units(currency, decimals)
        }

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  A v4 pool's price, tick and liquidity, read from the PoolManager's own
  storage: `Pool.State` lives at `keccak256(poolId . POOLS_SLOT)`, where word 0
  packs `sqrtPriceX96 | tick | protocolFee | lpFee` and word 3 is the
  liquidity. Nil when the pool has no price yet.
  """
  def pool_state(
        pool_manager,
        pool_id,
        token_is_currency0?,
        token_decimals,
        decimals,
        block,
        opts
      ) do
    state_slot = state_slot(pool_id)
    liquidity_slot = <<:binary.decode_unsigned(state_slot) + @liquidity_offset::256>>

    with {:ok, [slot0]} <- extsload(pool_manager, state_slot, block, opts),
         {:ok, [liquidity]} <- extsload(pool_manager, liquidity_slot, block, opts) do
      sqrt_price = slot0 |> rem(Integer.pow(2, 160))
      tick = slot0 |> div(Integer.pow(2, 160)) |> rem(Integer.pow(2, 24)) |> signed(24)

      case PoolPrice.currency_per_token(sqrt_price, token_is_currency0?, token_decimals, decimals) do
        {:ok, price} ->
          {:ok, %{sqrt_price_x96: sqrt_price, price: price, tick: tick, liquidity: liquidity}}

        {:error, :invalid_sqrt_price} ->
          {:ok, nil}
      end
    end
  end

  defp state_slot(pool_id) do
    {:ok, id} = Base.decode16(String.trim_leading(pool_id, "0x"), case: :lower)
    keccak(id <> <<@pools_slot::256>>)
  end

  defp extsload(pool_manager, slot, block, opts) do
    Rpc.call_words(
      pool_manager,
      @extsload_selector <> Base.encode16(slot, case: :lower),
      block,
      1,
      opts
    )
  end

  defp owner_of(position_manager, token_id, block, opts) do
    Rpc.call_address(
      position_manager,
      @owner_of_selector <> (token_id |> Integer.to_string(16) |> String.pad_leading(64, "0")),
      block,
      opts
    )
  end

  defp logs(address, from_block, block, topics, opts) do
    Rpc.request(
      "eth_getLogs",
      [
        %{
          address: address,
          fromBlock: hex(from_block),
          toBlock: hex(block.number),
          topics: topics
        }
      ],
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

  # Helpers

  defp currency0?(token, currency) do
    {:ok, token_bytes} = Address.decode(token)
    {:ok, currency_bytes} = Address.decode(currency)
    token_bytes < currency_bytes
  end

  defp percent(fee_hundredths_bps) when is_integer(fee_hundredths_bps) do
    # A v4 static fee is in hundredths of a bip: 3_000 is 0.30%.
    whole = div(fee_hundredths_bps, 10_000)
    fraction = rem(fee_hundredths_bps, 10_000)

    "#{whole}.#{fraction |> Integer.to_string() |> String.pad_leading(4, "0") |> String.slice(0, 2)}%"
  end

  defp bytes32(value) when is_integer(value),
    do:
      "0x" <> (value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))

  defp hex(value) when is_integer(value), do: "0x" <> Integer.to_string(value, 16)

  defp quantity("0x" <> hex), do: String.to_integer(hex, 16)

  defp topic_at(%{"topics" => topics}, index), do: topics |> Enum.at(index) |> downcase()

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)

  defp word("0x" <> hex), do: String.to_integer(hex, 16)

  defp data_words(%{"data" => "0x" <> hex}),
    do: for(<<word::binary-size(64) <- hex>>, do: String.to_integer(word, 16))

  defp signed(value, bits) do
    if value >= Integer.pow(2, bits - 1), do: value - Integer.pow(2, bits), else: value
  end

  defp keccak(bytes), do: :jose_jwa_sha3.keccak(1088, 512, bytes, 1, 32)
end
