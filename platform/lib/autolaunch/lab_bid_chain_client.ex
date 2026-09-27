defmodule Autolaunch.LabBidChainClient do
  @moduledoc false

  @behaviour Autolaunch.ChainClient

  alias Autolaunch.Chain.Abi

  alias Autolaunch.{Lab, LabAbi, LabRpc}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias RegentChain.Address

  @max_tick_walk 256
  @max_uint256 Integer.pow(2, 256) - 1

  # The auction's own `currency()` is the token every balance and allowance is
  # read from: REGENT for an Agent auction, the admitted stock for a Stocks one.
  @impl true
  def snapshot(%{auction: auction, signer: signer, max_price_q96: max_price}) do
    with {:ok, auction} <- Address.normalize(auction),
         {:ok, config, block, opts} <- LabRpc.current([:regent, :permit2]),
         :ok <- LabRpc.ensure_contract(auction, block, opts),
         {:ok, currency} <- call_address(config, auction, "currency()", [], block, opts),
         {:ok, currency_balance} <-
           LabRpc.call_uint(
             config,
             currency,
             "token",
             "balanceOf(address)",
             [signer],
             block,
             opts
           ),
         {:ok, token_allowance} <-
           LabRpc.call_uint(
             config,
             currency,
             "token",
             "allowance(address,address)",
             [signer, Lab.address!(config, :permit2)],
             block,
             opts
           ),
         {:ok, permit2_words} <-
           LabRpc.words(
             config,
             :permit2,
             "allowance(address,address,address)",
             [signer, currency, auction],
             3,
             block,
             opts
           ),
         [permit2_amount, permit2_expiration, _nonce] <- permit2_words,
         {:ok, spacing} <- call_uint(config, auction, "tickSpacing()", [], block, opts),
         {:ok, floor} <- call_uint(config, auction, "floorPrice()", [], block, opts),
         {:ok, start_block} <- call_uint(config, auction, "startBlock()", [], block, opts),
         :ok <- started(block, start_block),
         {:ok, [clearing, _raised, _mps_per_price, _mps, _prev, _next]} <-
           call_words(config, auction, "checkpoint()", [], 6, block, opts),
         {:ok, cap} <- call_uint(config, auction, "MAX_BID_PRICE()", [], block, opts),
         limits <- %{
           tick_spacing_q96: spacing,
           floor_price_q96: floor,
           clearing_price_q96: clearing,
           max_bid_price_q96: cap
         },
         {:ok, aligned} <- aligned_price(max_price, limits),
         {:ok, prev_tick_price_q96} <- predecessor(config, auction, aligned, block, opts) do
      {:ok,
       %{
         tick_spacing_q96: spacing,
         floor_price_q96: floor,
         clearing_price_q96: clearing,
         max_bid_price_q96: cap,
         auction: auction,
         currency: currency,
         currency_balance: currency_balance,
         token_allowance: token_allowance,
         permit2_amount: permit2_amount,
         permit2_expiration: permit2_expiration,
         prev_tick_price_q96: prev_tick_price_q96,
         predecessor_source: "bounded local auction tick walk",
         permit2: Lab.address!(config, :permit2)
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @doc """
  The USDC side of a Stocks bid: the wallet's USDC and its allowance to the bid
  adapter, and the admitted route's estimate of the STOCK `usdc_amount` buys.
  """
  def usdc_snapshot(%{stock: stock, signer: signer, usdc_amount: usdc_amount}) do
    with {:ok, config} <- StocksLab.current(),
         opts <- StocksLab.rpc_opts(config),
         {:ok, block} <- Autolaunch.Chain.Rpc.latest_block(opts),
         usdc <- StocksLab.address!(config, :usdc),
         adapter <- StocksLab.address!(config, :bid_adapter),
         launchpad <- StocksLab.address!(config, :launchpad),
         :ok <- LabRpc.ensure_contract(adapter, block, opts),
         {:ok, [admitted, _decimals, route_word]} <-
           Autolaunch.Chain.Rpc.call_words(
             launchpad,
             LabAbi.encode(StocksLab.abi!(config, :launchpad), "stockAdmission(address)", [stock]),
             block,
             3,
             opts
           ),
         true <- admitted != 0,
         {:ok, route} <- Abi.word_address(route_word),
         {:ok, usdc_balance} <-
           Autolaunch.Chain.Rpc.call_uint(
             usdc,
             LabAbi.encode(StocksLab.abi!(config, :erc20), "balanceOf(address)", [signer]),
             block,
             opts
           ),
         {:ok, usdc_allowance} <-
           Autolaunch.Chain.Rpc.call_uint(
             usdc,
             LabAbi.encode(StocksLab.abi!(config, :erc20), "allowance(address,address)", [
               signer,
               adapter
             ]),
             block,
             opts
           ),
         {:ok, stock_quote} <-
           Autolaunch.Chain.Rpc.call_uint(
             route,
             LabAbi.encode(
               StocksLab.abi!(config, :route),
               "quoteExactIn(address,address,uint256)",
               [
                 usdc,
                 stock,
                 usdc_amount
               ]
             ),
             block,
             opts
           ) do
      {:ok,
       %{
         usdc: usdc,
         adapter: adapter,
         route: route,
         usdc_balance: usdc_balance,
         usdc_allowance: usdc_allowance,
         stock_quote: stock_quote
       }}
    else
      false -> {:error, :stock_not_admitted}
      :error -> {:error, :invalid_chain_response}
      {:error, :stocks_deployment_missing} -> {:error, :usdc_bids_unavailable}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  # The auction refuses `checkpoint()` before its start block, so an auction
  # that has not opened is told apart from a chain that could not be read.
  defp started(%{number: number}, start_block) when number >= start_block, do: :ok
  defp started(_block, _start_block), do: {:error, :bid_preparation_unavailable}

  defp aligned_price(nil, _limits), do: {:ok, nil}
  defp aligned_price(price, limits), do: Autolaunch.BidPrice.align(price, limits)

  defp predecessor(config, auction, max_price, block, opts) when is_integer(max_price) do
    with {:ok, floor} <- call_uint(config, auction, "floorPrice()", [], block, opts),
         true <- floor < max_price do
      walk_ticks(config, auction, floor, max_price, block, opts, 0)
    else
      false -> {:error, :bid_preparation_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp predecessor(_config, _auction, nil, _block, _opts), do: {:ok, 0}

  defp walk_ticks(_config, _auction, _current, _max_price, _block, _opts, @max_tick_walk),
    do: {:error, :bid_preparation_unavailable}

  defp walk_ticks(config, auction, current, max_price, block, opts, hops) do
    with {:ok, [next, _demand]} <-
           call_words(config, auction, "ticks(uint256)", [current], 2, block, opts) do
      cond do
        next == @max_uint256 -> {:ok, current}
        next >= max_price -> {:ok, current}
        next > current -> walk_ticks(config, auction, next, max_price, block, opts, hops + 1)
        true -> {:error, :bid_preparation_unavailable}
      end
    end
  end

  defp call_address(config, address, signature, arguments, block, opts) do
    Autolaunch.Chain.Rpc.call_address(
      address,
      LabAbi.encode(Lab.abi!(config, :auction), signature, arguments),
      block,
      opts
    )
  end

  defp call_uint(config, address, signature, arguments, block, opts),
    do: LabRpc.call_uint(config, address, "auction", signature, arguments, block, opts)

  defp call_words(config, address, signature, arguments, count, block, opts),
    do: LabRpc.call_words(config, address, "auction", signature, arguments, count, block, opts)
end
