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

  alias Autolaunch.Chain.{Abi, Address, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.Assets

  @token_decimals 18
  @usdg_decimals 6
  @lane_bps 100
  @graduated 2
  # Every Robinhood memestock pool is created with this key; the fee hook
  # refuses any other tick spacing.
  @pool_fee 3_000
  @tick_spacing 60

  # Concrete-contract read the pinned interface ABIs do not carry: `ownerOf(uint256)`.
  @owner_of_selector "0x6352211e"

  @type t :: map()

  @doc "The lab's staking facts for one graduated auction address, or why they cannot be read."
  @spec read(String.t()) :: {:ok, t()} | {:error, atom()}
  def read(auction) when is_binary(auction) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         do: read_at(auction, config, block, opts)
  end

  @doc "The same facts at a block already read, on the deployment it was read with."
  @spec read_at(String.t(), map(), Rpc.block(), keyword()) :: {:ok, t()} | {:error, atom()}
  def read_at(auction, config, block, opts) when is_binary(auction) do
    with {:ok, auction} <- Address.normalize(auction) |> normalized(),
         {:ok, launch_id} <-
           launchpad_uint(config, "launchIdOfAuction(address)", [auction], block, opts),
         true <- launch_id > 0 || {:error, :unknown_auction},
         {:ok, words} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [launch_id],
             RobinhoodLabAbi.launch_record_words(),
             block,
             opts
           ),
         {:ok, launch} <- launch(words),
         {:ok, [stock_only_token_id, stock_only_used]} <-
           launchpad_words(config, "stockRecords(uint256)", [launch_id], 2, block, opts),
         {:ok, stock} <- Assets.fetch(Lab.chain_id(), launch.stock),
         {:ok, symbol} <-
           Rpc.call_string(launch.new_token, LabAbi.selector("symbol()"), block, opts),
         {:ok, positions} <-
           positions(config, launch, stock_only_token_id, stock_only_used, stock, block, opts),
         {:ok, fees} <- fees(config, launch, stock, block, opts) do
      {:ok,
       %{
         kind: :stocks,
         chain: :robinhood,
         block: block,
         launch_id: launch_id,
         pool_id: launch.pool_id,
         token: %{address: launch.new_token, symbol: symbol, decimals: @token_decimals},
         currency: %{address: launch.stock, symbol: stock.symbol, decimals: stock.decimals},
         token_is_currency0?: currency0?(launch.new_token, launch.stock),
         pool_fee: @pool_fee,
         tick_spacing: @tick_spacing,
         hook: Lab.address!(config, :stocks_hook),
         pool_manager: Lab.address!(config, :pool_manager),
         positions: positions,
         fees: fees
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every graduated launch on the lab at one block, newest first: its id, its
  token and its auction. Launch ids run from 1 to `nextLaunchId() - 1`.
  """
  @spec graduated(map(), map(), keyword()) ::
          {:ok, [%{launch_id: pos_integer(), token: String.t(), auction: String.t()}]}
          | {:error, atom()}
  def graduated(config, block, opts) do
    with {:ok, next_id} <- launchpad_uint(config, "nextLaunchId()", [], block, opts) do
      Enum.reduce_while(
        1..(next_id - 1)//1,
        {:ok, []},
        &collect_graduated(&1, &2, config, block, opts)
      )
    end
  end

  defp collect_graduated(launch_id, {:ok, found}, config, block, opts) do
    case graduated_launch(config, launch_id, block, opts) do
      {:ok, nil} -> {:cont, {:ok, found}}
      {:ok, launch} -> {:cont, {:ok, [launch | found]}}
      error -> {:halt, error}
    end
  end

  defp graduated_launch(config, launch_id, block, opts) do
    with {:ok, words} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [launch_id],
             RobinhoodLabAbi.launch_record_words(),
             block,
             opts
           ) do
      case launch(words) do
        {:ok, launch} ->
          {:ok, %{launch_id: launch_id, token: launch.new_token, auction: launch.auction}}

        {:error, :not_graduated} ->
          {:ok, nil}

        error ->
          error
      end
    end
  end

  defp normalized({:ok, address}), do: {:ok, address}
  defp normalized(:error), do: {:error, :invalid_auction}

  # `launches(id)`: launcher, newToken, currency, auction, startBlock, endBlock,
  # claimBlock, migrationBlock, requiredRaise, floorPriceQ96, lifecycle, poolId,
  # finalSqrtPriceX96, splitter, lpTokenId, lpCurrencyUsed, lpNewUsed, retiredNew.
  defp launch(words) do
    with {:ok, new_token} <- Abi.word_address(Enum.at(words, 1)),
         {:ok, stock} <- Abi.word_address(Enum.at(words, 2)),
         {:ok, auction} <- Abi.word_address(Enum.at(words, 3)),
         @graduated <- Enum.at(words, 10),
         {:ok, splitter} <- Abi.word_address(Enum.at(words, 13)) do
      {:ok,
       %{
         new_token: new_token,
         stock: stock,
         auction: auction,
         migration_block: Enum.at(words, 7),
         pool_id: bytes32(Enum.at(words, 11)),
         splitter: splitter,
         lp_token_id: Enum.at(words, 14),
         lp_stock_used: Enum.at(words, 15),
         lp_new_used: Enum.at(words, 16)
       }}
    else
      :error -> {:error, :invalid_chain_response}
      _lifecycle -> {:error, :not_graduated}
    end
  end

  # Both positions belong to the launchpad's locker, which never releases them
  # and forwards the fees it collects to the launch's splitter. Each carries
  # what a collection would deposit right now, simulated on the locker.
  defp positions(config, launch, stock_only_token_id, stock_only_used, stock, block, opts) do
    manager = Lab.address!(config, :position_manager)
    locker = Lab.address!(config, :stocks_locker)

    with {:ok, owner} <- owner_of(manager, launch.lp_token_id, block, opts),
         {:ok, one_sided} <-
           stock_only(config, launch, stock_only_token_id, stock_only_used, stock, block, opts) do
      {:ok,
       [
         %{
           key: :full_range,
           label: "Full range",
           token_id: launch.lp_token_id,
           owner: owner,
           locked?: Address.equal?(owner, locker),
           token_amount: Rpc.format_units(launch.lp_new_used, @token_decimals),
           currency_amount: Rpc.format_units(launch.lp_stock_used, stock.decimals),
           uncollected: uncollected(config, launch, launch.lp_token_id, stock, block, opts)
         }
       ] ++ one_sided}
    end
  end

  defp stock_only(_config, _launch, 0, _used, _stock, _block, _opts), do: {:ok, []}

  defp stock_only(config, launch, token_id, used, stock, block, opts) do
    manager = Lab.address!(config, :position_manager)
    locker = Lab.address!(config, :stocks_locker)

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
           currency_amount: Rpc.format_units(used, stock.decimals),
           uncollected: uncollected(config, launch, token_id, stock, block, opts)
         }
       ]}
    end
  end

  # `collect` simulated through `eth_call`: the fees a collection would deposit
  # into the splitter now, or nil when the simulation cannot answer.
  defp uncollected(config, launch, token_id, stock, block, opts) do
    locker = Lab.address!(config, :stocks_locker)
    data = LabAbi.encode(Lab.abi!(config, :stocks_locker), "collect(uint256)", [token_id])

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

  # The hook's two lanes for this pool, read from its own storage right now,
  # the wallet the Safe named to convert Regent's lane, and the splitter the
  # staker lane and the locker's LP fees flow to.
  defp fees(config, launch, stock, block, opts) do
    hook = Lab.address!(config, :stocks_hook)
    abi = Lab.abi!(config, :stocks_hook)

    with {:ok, [protocol_accrued, staker_accrued]} <-
           Rpc.call_words(
             hook,
             LabAbi.encode(abi, "accrued(bytes32)", [launch.pool_id]),
             block,
             2,
             opts
           ),
         {:ok, [_stock_converted, _usdg_deposited, stock_to_stakers]} <-
           Rpc.call_words(
             hook,
             LabAbi.encode(abi, "settled(bytes32)", [launch.pool_id]),
             block,
             3,
             opts
           ),
         {:ok, converter} <-
           Rpc.call_address(hook, LabAbi.encode(abi, "executor()", []), block, opts),
         {:ok, splitter} <- splitter_facts(config, launch.splitter, block, opts) do
      {:ok,
       %{
         lane_bps: @lane_bps,
         regent: %{
           accrued: Rpc.format_units(protocol_accrued, stock.decimals),
           accrued_atomic: protocol_accrued,
           converter: converter
         },
         stakers: %{
           accrued: Rpc.format_units(staker_accrued, stock.decimals),
           accrued_atomic: staker_accrued,
           settled_currency: Rpc.format_units(stock_to_stakers, stock.decimals)
         },
         splitter: splitter
       }}
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

  defp owner_of(position_manager, token_id, block, opts) do
    Rpc.call_address(
      position_manager,
      @owner_of_selector <> (token_id |> Integer.to_string(16) |> String.pad_leading(64, "0")),
      block,
      opts
    )
  end

  defp launchpad_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :stocks_launchpad),
      LabAbi.encode(Lab.abi!(config, :stocks_launchpad), signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_words(config, signature, arguments, count, block, opts) do
    Rpc.call_words(
      Lab.address!(config, :stocks_launchpad),
      LabAbi.encode(Lab.abi!(config, :stocks_launchpad), signature, arguments),
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
