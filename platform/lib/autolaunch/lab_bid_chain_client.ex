defmodule Autolaunch.LabBidChainClient do
  @moduledoc """
  The Base reads a bid is shown and reviewed from.

  `balances/1` answers what a wallet can bid with: the auction's own currency,
  the wallet's balance of it and, on a Stocks auction that takes USDC, its
  USDC. It reads nothing about the auction's bidding window, so a balance shows
  before an auction opens.

  `snapshot/1` answers the whole reviewed question at once, at the latest block,
  which it names (`block`): the auction's own currency, the wallet's balance of
  it, both allowances that stand between it and the auction, the auction's end
  block (`end_block`), and a tick below the bid's price for the canonical call
  (`Autolaunch.Chain.CcaLists.tick_hint/4`). There is no partial answer: a
  review is derived from one snapshot or from none.
  """

  alias Autolaunch.{BidPrice, Lab, LabAbi, LabRpc}
  alias Autolaunch.Chain.{Abi, CcaLists, Rpc}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias RegentChain.Address

  @typedoc """
  One reviewed bid's reads, every one at `block`: prices in Q96, amounts in
  the currency's smallest units.
  """
  @type snapshot :: %{
          tick_spacing_q96: pos_integer(),
          floor_price_q96: pos_integer(),
          clearing_price_q96: non_neg_integer(),
          max_bid_price_q96: pos_integer(),
          auction: String.t(),
          currency: String.t(),
          currency_balance: non_neg_integer(),
          token_allowance: non_neg_integer(),
          permit2_amount: non_neg_integer(),
          permit2_expiration: non_neg_integer(),
          prev_tick_price_q96: non_neg_integer(),
          predecessor_source: String.t(),
          permit2: String.t(),
          end_block: non_neg_integer(),
          block: Rpc.block()
        }

  @spec balances(map()) :: {:ok, map()} | {:error, atom()}
  def balances(%{auction: auction, signer: signer, usdc: usdc?}) do
    with {:ok, held} <- currency_balance(auction, signer),
         {:ok, usdc_balance} <- usdc_balance(usdc?, signer, held.block, held.opts) do
      {:ok,
       %{
         currency: held.currency,
         currency_balance: held.currency_balance,
         usdc_balance: usdc_balance
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @spec snapshot(%{
          auction: String.t(),
          signer: String.t(),
          max_price_q96: pos_integer()
        }) :: {:ok, snapshot()} | {:error, atom()}
  def snapshot(%{auction: auction, signer: signer, max_price_q96: max_price}) do
    with {:ok,
          %{
            auction: auction,
            config: config,
            block: block,
            opts: opts,
            currency: currency,
            currency_balance: currency_balance
          }} <- currency_balance(auction, signer),
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
         :ok <- in_time(block, start_block),
         {:ok, end_block} <- call_uint(config, auction, "endBlock()", [], block, opts),
         {:ok, clearing} <- clearing_price(config, auction, start_block, block, opts),
         {:ok, cap} <- call_uint(config, auction, "MAX_BID_PRICE()", [], block, opts),
         limits <- %{
           tick_spacing_q96: spacing,
           floor_price_q96: floor,
           clearing_price_q96: clearing,
           max_bid_price_q96: cap
         },
         {:ok, aligned} <- BidPrice.align(max_price, limits),
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
         permit2: Lab.address!(config, :permit2),
         end_block: end_block,
         block: block
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
  The adapter and the launchpad that admits the stock are those of the
  auction's own contracts `version`.
  """
  def usdc_snapshot(%{stock: stock, signer: signer, usdc_amount: usdc_amount, version: version}) do
    with {:ok, config} <- StocksLab.current(),
         {:ok, %{bid_adapter: adapter, launchpad: launchpad, abis: abis}} <-
           StocksLab.contracts(config, version),
         opts = StocksLab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         usdc = StocksLab.address!(config, :usdc),
         :ok <- LabRpc.ensure_contract(adapter, block, opts),
         {:ok, [admitted, _decimals, route_word]} <-
           Rpc.call_words(
             launchpad,
             LabAbi.encode(abis["launchpad"], "stockAdmission(address)", [stock]),
             block,
             3,
             opts
           ),
         true <- admitted != 0,
         {:ok, route} <- Abi.word_address(route_word),
         {:ok, usdc_balance} <-
           Rpc.call_uint(
             usdc,
             LabAbi.encode(StocksLab.abi!(config, :erc20), "balanceOf(address)", [signer]),
             block,
             opts
           ),
         {:ok, usdc_allowance} <-
           Rpc.call_uint(
             usdc,
             LabAbi.encode(StocksLab.abi!(config, :erc20), "allowance(address,address)", [
               signer,
               adapter
             ]),
             block,
             opts
           ),
         {:ok, stock_quote} <-
           Rpc.call_uint(
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

  # The auction's own `currency()` is the token every balance and allowance is
  # read from: REGENT for an Agent auction, the admitted stock for a Stocks one.
  defp currency_balance(auction, signer) do
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
           ) do
      {:ok,
       %{
         auction: auction,
         config: config,
         block: block,
         opts: opts,
         currency: currency,
         currency_balance: currency_balance
       }}
    end
  end

  # The auction takes a bid from its start block on, and a step prepared at the
  # latest block lands in the next one at the earliest, so a bid is open from
  # the block before the start. Earlier, it is told apart from a chain that
  # could not be read.
  defp in_time(%{number: number}, start_block) when number + 1 >= start_block, do: :ok
  defp in_time(_block, _start_block), do: {:error, :bid_preparation_unavailable}

  # The auction refuses `checkpoint()` before its start block. The block before
  # it, the stored clearing price is the floor the auction was created with,
  # which no bid can have moved yet.
  defp clearing_price(config, auction, start_block, %{number: number} = block, opts)
       when number < start_block,
       do: call_uint(config, auction, "clearingPrice()", [], block, opts)

  defp clearing_price(config, auction, _start_block, block, opts) do
    with {:ok, [clearing, _raised, _mps_per_price, _mps, _prev, _next]} <-
           call_words(config, auction, "checkpoint()", [], 6, block, opts),
         do: {:ok, clearing}
  end

  defp usdc_balance(false, _signer, _block, _opts), do: {:ok, nil}

  defp usdc_balance(true, signer, block, opts) do
    with {:ok, config} <- StocksLab.current() do
      Rpc.call_uint(
        StocksLab.address!(config, :usdc),
        LabAbi.encode(StocksLab.abi!(config, :erc20), "balanceOf(address)", [signer]),
        block,
        opts
      )
    end
  end

  # A tick the auction holds below the aligned price (`CcaLists.tick_hint/4`).
  defp predecessor(config, auction, max_price, block, opts) do
    read_next = fn price ->
      with {:ok, [next, _demand]} <-
             call_words(config, auction, "ticks(uint256)", [price], 2, block, opts),
           do: {:ok, next}
    end

    with {:ok, floor} <- call_uint(config, auction, "floorPrice()", [], block, opts),
         {:ok, next_active} <-
           Rpc.call_uint(auction, LabAbi.selector("nextActiveTickPrice()"), block, opts),
         do: CcaLists.tick_hint(read_next, floor, next_active, max_price)
  end

  defp call_address(config, address, signature, arguments, block, opts) do
    Rpc.call_address(
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
