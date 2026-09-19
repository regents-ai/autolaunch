defmodule Autolaunch.Pool do
  @moduledoc """
  Read-only pool facts for one graduated launch, read from the local Base fork.

  Agent launches graduate into a REGENT/SUBJECT pool recorded by the frozen
  strategy (`distribution(auction)`) and charged by the frozen `RegentFeeHook`;
  Stocks launches graduate into a NEW/STOCK pool recorded by the launchpad
  (`launches(id)`), charged by `StocksFeeHookV1` and locked in the launchpad's
  LP locker, whose fees flow to the launch's memestake splitter. Both are read
  at one latest block: the pool key and id, the price at graduation, the
  current pool price and liquidity from the PoolManager's own storage, the
  locked positions and their owner, the unsold tokens' fate, and the fee lanes
  with their totals.

  Nothing here writes, signs or caches; every figure is the fork's own answer.
  """

  alias Autolaunch.Chain.{Abi, Address, Rpc}
  alias Autolaunch.{Lab, LabAbi, LabProjection, LabRpc, PoolPrice}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @dead "0x000000000000000000000000000000000000dead"
  @token_decimals 18
  @regent_decimals 18
  @usdc_decimals 6
  @lane_bps 100
  @distribution_words 18
  @pools_slot 6
  @liquidity_offset 3
  @uniswap_pool_url "https://app.uniswap.org/explore/pools/base/"

  # Concrete-contract reads the pinned interface ABIs do not carry: fixed
  # selectors for `extsload(bytes32)` and `ownerOf(uint256)`.
  @extsload_selector "0x1e2eaeaf"
  @owner_of_selector "0x6352211e"

  @type t :: map()

  @doc "The lab's pool facts for one graduated auction row, or why they cannot be read."
  @spec read(map()) :: {:ok, t()} | {:error, atom()}
  def read(%{state: state}) when state != :graduated, do: {:error, :not_graduated}
  def read(%{kind: :agent} = auction), do: read_agent(auction)
  def read(%{kind: :stocks} = auction), do: read_stocks(auction)

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
    with {:ok, words} <-
           LabRpc.words(
             config,
             :strategy,
             "distribution(address)",
             [auction.auction_address],
             @distribution_words,
             block,
             opts
           ),
         {:ok, distribution} <- agent_distribution(words),
         do: {:ok, distribution.subject}
  end

  def token_address(%{kind: :stocks} = auction, config, block, opts) do
    with {:ok, launch_id} <-
           launchpad_uint(
             config,
             "launchIdOfAuction(address)",
             [auction.auction_address],
             block,
             opts
           ),
         {:ok, words} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [launch_id],
             StocksLabAbi.launch_record_words(),
             block,
             opts
           ),
         {:ok, launch} <- stocks_launch(words),
         do: {:ok, launch.new_token}
  end

  # Agent

  defp read_agent(auction) do
    with {:ok, config} <- Lab.current(),
         opts <- LabRpc.opts(config, "autolaunch pool page"),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, words} <-
           LabRpc.words(
             config,
             :strategy,
             "distribution(address)",
             [auction.auction_address],
             @distribution_words,
             block,
             opts
           ),
         {:ok, distribution} <- agent_distribution(words),
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
         {:ok, owner} <-
           owner_of(
             Lab.address!(config, :position_manager),
             distribution.lp_token_id,
             block,
             opts
           ),
         {:ok, fees} <-
           agent_fees(config, distribution, auction, block, opts) do
      {:ok,
       %{
         kind: :agent,
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
         pool_manager: Lab.address!(config, :pool_manager),
         graduation_price: graduation_price,
         current: current,
         positions: [
           %{
             label: "Full range",
             token_id: distribution.lp_token_id,
             owner: owner,
             locked?: Address.equal?(owner, @dead),
             token_amount: Rpc.format_units(distribution.lp_subject_used, @token_decimals),
             currency_amount: Rpc.format_units(distribution.lp_regent_used, @regent_decimals)
           }
         ],
         unsold: %{
           amount: Rpc.format_units(unsold, @token_decimals),
           disposition: :escrow,
           address: distribution.escrow
         },
         uniswap_url: uniswap_url(distribution.pool_id),
         fees: fees
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp agent_distribution(words) do
    with {:ok, subject} <- Abi.word_address(Enum.at(words, 11)),
         {:ok, escrow} <- Abi.word_address(Enum.at(words, 12)),
         {:ok, splitter} <- Abi.word_address(Enum.at(words, 14)),
         {:ok, receiver} <- Abi.word_address(Enum.at(words, 15)),
         pool_id when pool_id != 0 <- Enum.at(words, 16) do
      {:ok,
       %{
         migration_block: Enum.at(words, 4),
         lp_regent_used: Enum.at(words, 7),
         lp_subject_used: Enum.at(words, 8),
         final_sqrt_price_x96: Enum.at(words, 9),
         subject: subject,
         escrow: escrow,
         splitter: splitter,
         receiver: receiver,
         pool_id: bytes32(pool_id),
         lp_token_id: Enum.at(words, 17)
       }}
    else
      0 -> {:error, :not_graduated}
      :error -> {:error, :invalid_chain_response}
    end
  end

  # Every `SwapFeeSettled` this pool emitted since graduation, summed per fee
  # token. Each lane is the same amount, so one total per token names both.
  defp agent_fees(config, distribution, auction, block, opts) do
    hook = Lab.address!(config, :hook)

    with {:ok, logs} <-
           logs(hook, distribution.migration_block, block, [nil, distribution.pool_id], opts) do
      topic = LabAbi.topic(LabAbi.swap_fee_settled_signature())

      settled =
        logs
        |> Enum.filter(&(topic_at(&1, 0) == topic))
        |> Enum.map(fn log ->
          {:ok, fee_token} = log |> topic_at(3) |> word() |> Abi.word_address()
          [_fee_base, lane, _exact_input] = data_words(log)
          {fee_token, lane}
        end)

      per_token =
        Enum.reduce(settled, %{}, fn {token, lane}, sums ->
          Map.update(sums, String.downcase(token), lane, &(&1 + lane))
        end)

      regent = Lab.address!(config, :regent)

      {:ok,
       %{
         lane_bps: @lane_bps,
         splitter: distribution.splitter,
         receiver: distribution.receiver,
         subject_path: "/subjects/" <> LabProjection.subject_identity(distribution.subject),
         swaps: length(settled),
         per_lane: %{
           currency: Rpc.format_units(Map.get(per_token, regent, 0), @regent_decimals),
           token:
             Rpc.format_units(
               Map.get(per_token, String.downcase(distribution.subject), 0),
               @token_decimals
             )
         },
         token_symbol: auction.token_symbol
       }}
    end
  end

  # Stocks

  defp read_stocks(auction) do
    with {:ok, config} <- StocksLab.current(),
         opts <- StocksLab.rpc_opts(config, "autolaunch pool page"),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, launch_id} <-
           launchpad_uint(
             config,
             "launchIdOfAuction(address)",
             [auction.auction_address],
             block,
             opts
           ),
         {:ok, words} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [launch_id],
             StocksLabAbi.launch_record_words(),
             block,
             opts
           ),
         {:ok, launch} <- stocks_launch(words),
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
         {:ok, positions} <- stocks_positions(config, launch, decimals, block, opts),
         {:ok, fees} <- stocks_fees(config, launch, decimals, block, opts) do
      {:ok,
       %{
         kind: :stocks,
         chain: :base,
         block: block,
         launch_id: launch_id,
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
         lp_fee: percent(3_000),
         pool_fee: 3_000,
         tick_spacing: 60,
         hook: StocksLab.address!(config, :hook),
         pool_manager: StocksLab.address!(config, :pool_manager),
         graduation_price: graduation_price,
         current: current,
         positions: positions,
         unsold: %{
           amount: Rpc.format_units(launch.retired_new, @token_decimals),
           disposition: :retired,
           address: @dead
         },
         uniswap_url: uniswap_url(launch.pool_id),
         fees: fees
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stocks_launch(words) do
    with {:ok, new_token} <- Abi.word_address(Enum.at(words, 1)),
         {:ok, stock} <- Abi.word_address(Enum.at(words, 2)),
         {:ok, splitter} <- Abi.word_address(Enum.at(words, 4)),
         2 <- Enum.at(words, 11) do
      {:ok,
       %{
         new_token: new_token,
         stock: stock,
         splitter: splitter,
         migration_block: Enum.at(words, 8),
         pool_id: bytes32(Enum.at(words, 12)),
         final_sqrt_price_x96: Enum.at(words, 13),
         lp_token_id: Enum.at(words, 14),
         lp_stock_used: Enum.at(words, 15),
         lp_new_used: Enum.at(words, 16),
         retired_new: Enum.at(words, 17),
         lp_stock_only_token_id: Enum.at(words, 18),
         lp_stock_only_used: Enum.at(words, 19)
       }}
    else
      :error -> {:error, :invalid_chain_response}
      _lifecycle -> {:error, :not_graduated}
    end
  end

  # Both positions belong to the launchpad's locker, which never releases them
  # and forwards the fees it collects to the launch's splitter. Each carries
  # what a collection would deposit right now, simulated on the locker.
  defp stocks_positions(config, launch, decimals, block, opts) do
    manager = StocksLab.address!(config, :position_manager)
    locker = StocksLab.address!(config, :locker)

    with {:ok, owner} <- owner_of(manager, launch.lp_token_id, block, opts),
         {:ok, one_sided} <- stock_only_position(config, launch, decimals, block, opts) do
      {:ok,
       [
         %{
           key: :full_range,
           label: "Full range",
           token_id: launch.lp_token_id,
           owner: owner,
           locked?: Address.equal?(owner, locker),
           token_amount: Rpc.format_units(launch.lp_new_used, @token_decimals),
           currency_amount: Rpc.format_units(launch.lp_stock_used, decimals),
           uncollected: uncollected(config, launch, launch.lp_token_id, decimals, block, opts)
         }
       ] ++ one_sided}
    end
  end

  defp stock_only_position(_config, %{lp_stock_only_token_id: 0}, _decimals, _block, _opts),
    do: {:ok, []}

  defp stock_only_position(config, launch, decimals, block, opts) do
    manager = StocksLab.address!(config, :position_manager)
    locker = StocksLab.address!(config, :locker)
    token_id = launch.lp_stock_only_token_id

    with {:ok, owner} <- owner_of(manager, token_id, block, opts) do
      {:ok,
       [
         %{
           key: :stock_only,
           label: "One-sided (currency only)",
           token_id: token_id,
           owner: owner,
           locked?: Address.equal?(owner, locker),
           token_amount: "0",
           currency_amount: Rpc.format_units(launch.lp_stock_only_used, decimals),
           uncollected: uncollected(config, launch, token_id, decimals, block, opts)
         }
       ]}
    end
  end

  # `collect` simulated through `eth_call`: the fees a collection would deposit
  # into the splitter now, or nil when the simulation cannot answer.
  defp uncollected(config, launch, token_id, decimals, block, opts) do
    data = LabAbi.encode(StocksLab.abi!(config, :locker), "collect(uint256)", [token_id])

    case Rpc.call_words(StocksLab.address!(config, :locker), data, block, 2, opts) do
      {:ok, [amount0, amount1]} ->
        {token, currency} =
          if currency0?(launch.new_token, launch.stock),
            do: {amount0, amount1},
            else: {amount1, amount0}

        %{
          token_amount: Rpc.format_units(token, @token_decimals),
          currency_amount: Rpc.format_units(currency, decimals)
        }

      {:error, _reason} ->
        nil
    end
  end

  # The hook's two lanes for this pool, read from its own storage right now,
  # plus every accrual and settlement it emitted since graduation, and the
  # splitter the staker lane and the locker's LP fees flow to.
  defp stocks_fees(config, launch, decimals, block, opts) do
    hook = StocksLab.address!(config, :hook)
    abi = StocksLab.abi!(config, :hook)

    with {:ok, [regent_accrued, staker_accrued]} <-
           Rpc.call_words(
             hook,
             LabAbi.encode(abi, "accrued(bytes32)", [launch.pool_id]),
             block,
             2,
             opts
           ),
         {:ok, [stock_converted, usdc_deposited, stock_to_stakers]} <-
           Rpc.call_words(
             hook,
             LabAbi.encode(abi, "settled(bytes32)", [launch.pool_id]),
             block,
             3,
             opts
           ),
         {:ok, splitter} <- splitter_facts(config, launch.splitter, block, opts),
         {:ok, logs} <- logs(hook, launch.migration_block, block, [nil, launch.pool_id], opts) do
      accrued_topic = LabAbi.topic(StocksLabAbi.hook_fee_accrued_signature())
      regent_topic = LabAbi.topic(StocksLabAbi.regent_lane_settled_signature())
      staker_topic = LabAbi.topic(StocksLabAbi.staker_lane_settled_signature())

      {:ok,
       %{
         lane_bps: @lane_bps,
         trades: Enum.count(logs, &(topic_at(&1, 0) == accrued_topic)),
         regent: %{
           accrued: Rpc.format_units(regent_accrued, decimals),
           settled_currency: Rpc.format_units(stock_converted, decimals),
           settled_usdc: Rpc.format_units(usdc_deposited, @usdc_decimals)
         },
         stakers: %{
           accrued: Rpc.format_units(staker_accrued, decimals),
           accrued_atomic: staker_accrued,
           settled_currency: Rpc.format_units(stock_to_stakers, decimals)
         },
         splitter: splitter,
         settlements:
           logs
           |> Enum.filter(&(topic_at(&1, 0) in [regent_topic, staker_topic]))
           |> Enum.map(&settlement(&1, regent_topic, decimals))
       }}
    end
  end

  # The memestake splitter of a graduated launch: what is staked in it, the
  # skim it keeps from every unstake, and the dollar it pays out in.
  defp splitter_facts(config, splitter, block, opts) do
    abi = StocksLab.abi!(config, :splitter)

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
         dollar: %{address: dollar, symbol: "USDC", decimals: @usdc_decimals}
       }}
    end
  end

  defp settlement(log, regent_topic, decimals) do
    if topic_at(log, 0) == regent_topic do
      [stock_converted, usdc_deposited] = data_words(log)

      %{
        lane: :regent,
        currency: Rpc.format_units(stock_converted, decimals),
        usdc: Rpc.format_units(usdc_deposited, @usdc_decimals),
        block: quantity(log["blockNumber"]),
        transaction_hash: log["transactionHash"]
      }
    else
      [amount] = data_words(log)

      %{
        lane: :stakers,
        currency: Rpc.format_units(amount, decimals),
        usdc: nil,
        block: quantity(log["blockNumber"]),
        transaction_hash: log["transactionHash"]
      }
    end
  end

  # Shared chain reads

  # `Pool.State` lives at `keccak256(poolId . POOLS_SLOT)`: word 0 packs
  # `sqrtPriceX96 | tick | protocolFee | lpFee`, word 3 is the liquidity.
  defp pool_state(
         pool_manager,
         pool_id,
         token_is_currency0?,
         token_decimals,
         decimals,
         block,
         opts
       ) do
    {:ok, id} = Base.decode16(String.trim_leading(pool_id, "0x"), case: :lower)
    state_slot = keccak(id <> <<@pools_slot::256>>)
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

  defp launchpad_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      StocksLab.address!(config, :launchpad),
      LabAbi.encode(StocksLab.abi!(config, :launchpad), signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_words(config, signature, arguments, count, block, opts) do
    Rpc.call_words(
      StocksLab.address!(config, :launchpad),
      LabAbi.encode(StocksLab.abi!(config, :launchpad), signature, arguments),
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
