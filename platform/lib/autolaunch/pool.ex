defmodule Autolaunch.Pool do
  @moduledoc """
  Read-only pool facts for one graduated launch, read from the local Base fork.

  Agent launches graduate into a REGENT/SUBJECT pool recorded by the frozen
  strategy (`distribution(auction)`) and charged by the frozen `RegentFeeHook`;
  Stocks launches graduate into a NEW/STOCK pool recorded by the launchpad
  (`launches(id)`) and charged by `StocksFeeHookV1`. Both are read at one latest
  block: the pool key and id, the price at graduation, the current pool price
  and liquidity from the PoolManager's own storage, the locked positions and
  their owner, the unsold tokens' fate, and the fee lanes with their totals.

  Nothing here writes, signs or caches; every figure is the fork's own answer.
  """

  alias Autolaunch.Chain.{Abi, Address, Rpc}
  alias Autolaunch.{Lab, LabAbi, LabProjection, LabRpc, PoolPrice}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @dead "0x000000000000000000000000000000000000dead"
  @zero_address "0x" <> String.duplicate("0", 40)
  @token_decimals 18
  @regent_decimals 18
  @usdc_decimals 6
  @lane_bps 100
  @distribution_words 18
  @pools_slot 6
  @liquidity_offset 3
  @uniswap_pool_url "https://app.uniswap.org/explore/pools/base/"

  # Concrete-contract reads the pinned interface ABIs do not carry: fixed
  # selectors and topics, exactly as the launch client names `subject()`.
  @extsload_selector "0x1e2eaeaf"
  @owner_of_selector "0x6352211e"
  @executor_selector "0xc34c08e5"
  @pool_registered_topic Abi.topic0("PoolRegistered(bytes32,address,address,address)")
  @subject_lane_set_topic Abi.topic0("SubjectLaneSet(bytes32,address,address)")

  @type t :: map()

  @doc "The lab's pool facts for one graduated auction row, or why they cannot be read."
  @spec read(map()) :: {:ok, t()} | {:error, atom()}
  def read(%{state: state}) when state != :graduated, do: {:error, :not_graduated}
  def read(%{kind: :agent} = auction), do: read_agent(auction)
  def read(%{kind: :stocks} = auction), do: read_stocks(auction)

  @doc "The public Base pool page on the Uniswap app for a pool id."
  def uniswap_url(pool_id), do: @uniswap_pool_url <> pool_id

  def dead_address, do: @dead

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
         {:ok, subject} <- subject_config(config, launch_id, block, opts),
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
         {:ok, fees} <- stocks_fees(config, launch, subject, decimals, block, opts) do
      {:ok,
       %{
         kind: :stocks,
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
         {:ok, administrator} <- Abi.word_address(Enum.at(words, 4)),
         2 <- Enum.at(words, 11) do
      {:ok,
       %{
         new_token: new_token,
         stock: stock,
         administrator: administrator,
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

  @doc "The launchpad's current subject lane configuration of one launch id."
  def subject_config(config, launch_id, block, opts) do
    with {:ok, [version, splitter, bps, administrator, proposed]} <-
           launchpad_words(config, "subjectConfig(uint256)", [launch_id], 5, block, opts),
         {:ok, administrator} <- Abi.word_address(administrator) do
      {:ok,
       %{
         version: version,
         splitter: optional_address(splitter),
         subject_bps: bps,
         administrator: administrator,
         proposed_administrator: optional_address(proposed)
       }}
    end
  end

  defp stocks_positions(config, launch, decimals, block, opts) do
    manager = StocksLab.address!(config, :position_manager)

    with {:ok, owner} <- owner_of(manager, launch.lp_token_id, block, opts),
         {:ok, one_sided} <- stock_only_position(manager, launch, decimals, block, opts) do
      {:ok,
       [
         %{
           label: "Full range",
           token_id: launch.lp_token_id,
           owner: owner,
           locked?: Address.equal?(owner, @dead),
           token_amount: Rpc.format_units(launch.lp_new_used, @token_decimals),
           currency_amount: Rpc.format_units(launch.lp_stock_used, decimals)
         }
       ] ++ one_sided}
    end
  end

  defp stock_only_position(_manager, %{lp_stock_only_token_id: 0}, _decimals, _block, _opts),
    do: {:ok, []}

  defp stock_only_position(manager, launch, decimals, block, opts) do
    with {:ok, owner} <- owner_of(manager, launch.lp_stock_only_token_id, block, opts) do
      {:ok,
       [
         %{
           label: "One-sided (currency only)",
           token_id: launch.lp_stock_only_token_id,
           owner: owner,
           locked?: Address.equal?(owner, @dead),
           token_amount: "0",
           currency_amount: Rpc.format_units(launch.lp_stock_only_used, decimals)
         }
       ]}
    end
  end

  # Every destination that ever held this pool's subject lane, found from the
  # hook's own registration and lane-change events since graduation, then each
  # destination's accrued and settled figures read from the hook right now.
  defp stocks_fees(config, launch, subject, decimals, block, opts) do
    hook = StocksLab.address!(config, :hook)
    abi = StocksLab.abi!(config, :hook)

    with {:ok, regent_destination} <-
           Rpc.call_address(
             hook,
             LabAbi.encode(abi, "REGENT_DESTINATION()", []),
             block,
             opts
           ),
         {:ok, executor} <- Rpc.call_address(hook, @executor_selector, block, opts),
         {:ok, logs} <- logs(hook, launch.migration_block, block, [nil, launch.pool_id], opts),
         destinations <- lane_destinations(logs, subject.splitter),
         {:ok, subject_buckets} <-
           buckets(config, hook, abi, launch.pool_id, destinations, decimals, block, opts),
         {:ok, [regent_bucket]} <-
           buckets(config, hook, abi, launch.pool_id, [regent_destination], decimals, block, opts) do
      accrued_topic = LabAbi.topic(StocksLabAbi.hook_fee_accrued_signature())
      settled_topic = LabAbi.topic(StocksLabAbi.bucket_settled_signature())

      {:ok,
       %{
         lane_bps: @lane_bps,
         config: subject,
         regent_destination: regent_destination,
         executor: executor,
         regent_bucket: regent_bucket,
         subject_buckets: subject_buckets,
         trades: Enum.count(logs, &(topic_at(&1, 0) == accrued_topic)),
         settlements:
           logs
           |> Enum.filter(&(topic_at(&1, 0) == settled_topic))
           |> Enum.map(&settlement(&1, decimals))
       }}
    end
  end

  # The splitter registered at graduation, every previous/current pair of a
  # later lane change, and the one configured now; zero means "off" and is not
  # a destination.
  defp lane_destinations(logs, current) do
    registered =
      logs
      |> Enum.filter(&(topic_at(&1, 0) == @pool_registered_topic))
      |> Enum.map(fn log -> log |> data_words() |> hd() end)

    changed =
      logs
      |> Enum.filter(&(topic_at(&1, 0) == @subject_lane_set_topic))
      |> Enum.flat_map(fn log -> [word(topic_at(log, 2)), word(topic_at(log, 3))] end)

    (registered ++ changed)
    |> Enum.map(&optional_address/1)
    |> Kernel.++([current])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp buckets(_config, hook, abi, pool_id, destinations, decimals, block, opts) do
    Enum.reduce_while(destinations, {:ok, []}, fn destination, {:ok, acc} ->
      with {:ok, accrued} <-
             Rpc.call_uint(
               hook,
               LabAbi.encode(abi, "accrued(bytes32,address)", [pool_id, destination]),
               block,
               opts
             ),
           {:ok, [stock_converted, usdc_deposited]} <-
             Rpc.call_words(
               hook,
               LabAbi.encode(abi, "settled(bytes32,address)", [pool_id, destination]),
               block,
               2,
               opts
             ) do
        {:cont,
         {:ok,
          acc ++
            [
              %{
                destination: destination,
                accrued: Rpc.format_units(accrued, decimals),
                accrued_atomic: accrued,
                settled_currency: Rpc.format_units(stock_converted, decimals),
                settled_usdc: Rpc.format_units(usdc_deposited, @usdc_decimals)
              }
            ]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp settlement(log, decimals) do
    [stock_converted, usdc_deposited, _source_ref] = data_words(log)
    {:ok, destination} = log |> topic_at(2) |> word() |> Abi.word_address()

    %{
      destination: destination,
      currency: Rpc.format_units(stock_converted, decimals),
      usdc: Rpc.format_units(usdc_deposited, @usdc_decimals),
      block: quantity(log["blockNumber"]),
      transaction_hash: log["transactionHash"]
    }
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

  defp optional_address(0), do: nil

  defp optional_address(word) when is_integer(word) do
    case Abi.word_address(word) do
      {:ok, address} -> address
      :error -> nil
    end
  end

  defp optional_address(@zero_address), do: nil
  defp optional_address(address) when is_binary(address), do: address

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
