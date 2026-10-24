defmodule Autolaunch.AuctionMarket.Read do
  @moduledoc """
  One auction's contract as its reading job reads it (`Autolaunch.AuctionMarket`),
  all at one block: its state, price, amount raised and terms, its bidders'
  positions once it has ended, its token's pool price and, on Base, everything
  its own page shows (`Autolaunch.AuctionSnapshot.page/6`).

  Each auction reads through its deployment (`venue/1`): a Base Revstake
  auction through the lab contracts (`Autolaunch.Lab`), a Base Memestock
  auction through the launchpad of its own contracts version
  (`Autolaunch.Stocks.Lab`), and a Robinhood auction against the rollup clock
  its contracts keep time by (`Autolaunch.Robinhood.Launchpad`).
  """

  require Logger

  alias Autolaunch.Auction.MarketState
  alias Autolaunch.{AuctionSnapshot, AuctionTerms, Lab, LabAbi, LabPositions, LabRpc, Pool}
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.Launchpad
  alias Autolaunch.Stocks.Amounts
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @token_decimals 18

  @doc "The chain and kind of each deployment this site describes."
  @spec venues() :: [{pos_integer(), :agent | :stocks}]
  def venues do
    for {lab, kind} <- [{Lab, :agent}, {StocksLab, :stocks}, {RobinhoodLab, :stocks}],
        {:ok, config} <- [lab.current()],
        uniq: true,
        do: {config.chain_id, kind}
  end

  @doc "The deployment `auction` reads through, while this site describes it."
  def venue(%{chain_id: chain, kind: kind}) do
    cond do
      RobinhoodLab.chain?(chain) ->
        venue(:robinhood, RobinhoodLab.current(), chain, &RobinhoodLab.rpc_opts/1)

      kind == :stocks ->
        venue(:stocks, StocksLab.current(), chain, &StocksLab.rpc_opts(&1, "auction market"))

      true ->
        venue(:agent, Lab.current(), chain, &Lab.rpc_opts(&1, "auction market"))
    end
  end

  defp venue(venue, {:ok, %{chain_id: chain} = config}, chain, opts),
    do: {:ok, %{venue: venue, config: config, opts: opts.(config)}}

  defp venue(_venue, _config, _chain, _opts), do: {:error, :chain_unavailable}

  @doc """
  The newest block of the auction's deployment, with the block its contracts
  keep time by (`clock`). A Base Revstake head needs the lab's strategy
  contract live at it.
  """
  def head(%{venue: :agent}) do
    with {:ok, _config, block, _opts} <- LabRpc.current([:strategy]),
         do: {:ok, %{block: block, clock: block.number}}
  end

  def head(%{venue: :stocks, opts: opts}) do
    with {:ok, block} <- Rpc.latest_block(opts), do: {:ok, %{block: block, clock: block.number}}
  end

  def head(%{venue: :robinhood}), do: Launchpad.head()

  @doc """
  Everything one pass writes for `auction` at `head`: the figures its row
  takes, its bidders' positions, its token's pool price, its reading's
  `market` and, on Base, its `page`, read with the ladder its last reading
  holds. A Base page that could not be read is `:unread`.
  """
  def snapshot(%{venue: :agent, config: config, opts: opts}, %{block: block}, auction, ladder) do
    address = auction.auction_address

    with :ok <- LabRpc.ensure_contract(address, block, opts),
         {:ok, start_block} <- lab_uint(config, address, "startBlock()", block, opts),
         {:ok, end_block} <- lab_uint(config, address, "endBlock()", block, opts),
         {:ok, claim_block} <- lab_uint(config, address, "claimBlock()", block, opts),
         {:ok, minimum_reached} <- lab_bool(config, address, "isGraduated()", block, opts),
         {:ok, clearing} <- lab_uint(config, address, "clearingPrice()", block, opts),
         {:ok, raised} <- lab_uint(config, address, "currencyRaised()", block, opts),
         {:ok, remaining} <- lab_uint(config, address, "remainingSupply()", block, opts),
         {:ok, terms} <- AuctionTerms.read(auction, &Lab.format_price/1, block, opts),
         {:ok, distribution} <-
           LabRpc.words(
             config,
             :strategy,
             "distribution(address)",
             [address],
             LabAbi.distribution_words(),
             block,
             opts
           ),
         {:ok, price_quote} <- Pool.agent_price_quote(config, distribution, block, opts),
         %{lifecycle: lifecycle} = LabAbi.distribution(distribution),
         state = MarketState.observed(lifecycle, block.number, start_block, end_block),
         {:ok, positions} <-
           positions(Lab.abi!(config, :auction), auction, end_block, claim_block, block, opts),
         {:ok, page} <- page(auction, state, config, block, opts, ladder) do
      raised = Rpc.format_units(raised, @token_decimals)

      {:ok,
       %{
         block: block,
         state: state,
         current_clearing_price: Lab.format_price(clearing),
         minimum_reached: minimum_reached,
         currency_raised: raised,
         terms: terms,
         positions: positions,
         price_quote: price_quote,
         market: %{
           start_block: start_block,
           end_block: end_block,
           claim_block: claim_block,
           currency_raised: raised,
           remaining_supply: Rpc.format_units(remaining, @token_decimals),
           price_quote: price_quote
         },
         page: page
       }}
    end
  end

  def snapshot(%{venue: :stocks, config: config, opts: opts}, %{block: block}, auction, ladder) do
    address = auction.auction_address
    decimals = auction.quote_token_decimals
    price = &Amounts.format_cca_price(&1, decimals, @token_decimals)

    with {:ok, contracts} <- StocksLab.contracts(config, auction.contracts_version),
         :ok <- LabRpc.ensure_contract(address, block, opts),
         {:ok, start_block} <- stocks_uint(config, address, "startBlock()", block, opts),
         {:ok, end_block} <- stocks_uint(config, address, "endBlock()", block, opts),
         {:ok, claim_block} <- stocks_uint(config, address, "claimBlock()", block, opts),
         {:ok, minimum_reached} <- stocks_bool(config, address, "isGraduated()", block, opts),
         {:ok, clearing} <- stocks_uint(config, address, "clearingPrice()", block, opts),
         {:ok, raised} <- stocks_uint(config, address, "currencyRaised()", block, opts),
         {:ok, remaining} <- stocks_uint(config, address, "remainingSupply()", block, opts),
         {:ok, terms} <- AuctionTerms.read(auction, price, block, opts),
         {:ok, launch_id} <-
           Rpc.call_uint(
             contracts.launchpad,
             LabAbi.encode(contracts.abis["launchpad"], "launchIdOfAuction(address)", [address]),
             block,
             opts
           ),
         {:ok, words} <-
           Rpc.call_words(
             contracts.launchpad,
             LabAbi.encode(contracts.abis["launchpad"], "launches(uint256)", [launch_id]),
             block,
             contracts.record_words,
             opts
           ),
         record = StocksLabAbi.record(contracts, words),
         {:ok, price_quote} <- Pool.stocks_price_quote(config, record, decimals, block, opts),
         state = MarketState.observed(record.lifecycle, block.number, start_block, end_block),
         {:ok, positions} <-
           positions(
             StocksLab.abi!(config, :auction),
             auction,
             end_block,
             claim_block,
             block,
             opts
           ),
         {:ok, page} <- page(auction, state, config, block, opts, ladder) do
      raised = Rpc.format_units(raised, decimals)

      {:ok,
       %{
         block: block,
         state: state,
         current_clearing_price: price.(clearing),
         minimum_reached: minimum_reached,
         currency_raised: raised,
         terms: terms,
         positions: positions,
         price_quote: price_quote,
         market: %{
           start_block: start_block,
           end_block: end_block,
           claim_block: claim_block,
           currency_raised: raised,
           remaining_supply: Rpc.format_units(remaining, @token_decimals),
           price_quote: price_quote
         },
         page: page
       }}
    end
  end

  # Robinhood keeps no page: its auction page reads the chain itself. A pool
  # price that cannot be read is logged and left out; the auction's own
  # figures still stand.
  def snapshot(%{venue: :robinhood}, head, auction, _ladder) do
    decimals = auction.quote_token_decimals
    price = &Amounts.format_cca_price(&1, decimals, @token_decimals)

    with {:ok, market} <- Launchpad.market(head, auction),
         {:ok, terms} <- Launchpad.terms(head, auction, price) do
      raised = Rpc.format_units(market.currency_raised, decimals)
      price_quote = pool_price(head, auction, market.pool)

      {:ok,
       %{
         block: head.block,
         state:
           MarketState.observed(
             market.lifecycle,
             head.clock,
             market.start_block,
             market.end_block
           ),
         current_clearing_price: price.(market.clearing_price_q96),
         minimum_reached: market.minimum_reached,
         currency_raised: raised,
         terms: terms,
         positions: [],
         price_quote: price_quote,
         market: %{
           start_block: market.start_block,
           end_block: market.end_block,
           claim_block: nil,
           currency_raised: raised,
           remaining_supply: nil,
           price_quote: price_quote
         },
         page: nil
       }}
    end
  end

  defp pool_price(_head, _auction, nil), do: nil

  defp pool_price(head, auction, pool) do
    case Launchpad.price_quote(head, pool, auction.quote_token_decimals) do
      {:ok, price_quote} ->
        price_quote

      {:error, reason} ->
        Logger.warning("Pool price for auction #{auction.id} not read: #{inspect(reason)}")
        nil
    end
  end

  # After the end block, every site position of this auction is read back from
  # the auction's own `bids(bidId)` so its status follows the contract.
  defp positions(abi, auction, end_block, claim_block, block, opts) do
    if block.number >= end_block do
      with {:ok, rows} <- LabPositions.positions(auction.id) do
        LabPositions.read(
          abi,
          rows,
          auction.auction_address,
          %{end_block: end_block, claim_block: claim_block},
          block,
          opts
        )
      end
    else
      {:ok, []}
    end
  end

  # A page that cannot be read is one warning line and `:unread`: the
  # auction's own figures are still written, and its page stays as last read,
  # marked. A ladder that keeps stopping (more prices than it lists, or a chain
  # too slow to read them in a pass) shows here without anyone opening its page.
  defp page(auction, state, config, block, opts, ladder) do
    state = MarketState.join(auction.state, state)
    pool = Pool.read_at(%{auction | state: state}, config, block, opts)

    case AuctionSnapshot.page(auction, state, pool, block, opts, ladder) do
      {:ok, page} ->
        if not page.ladder.complete?,
          do: :telemetry.execute([:autolaunch, :auction_page, :ladder_stopped], %{count: 1}, %{})

        {:ok, page}

      {:error, reason} ->
        Logger.warning("Page of auction #{auction.id} not read: #{inspect(reason)}")
        {:ok, :unread}
    end
  end

  defp lab_uint(config, address, signature, block, opts),
    do: LabRpc.call_uint(config, address, "auction", signature, [], block, opts)

  defp lab_bool(config, address, signature, block, opts),
    do: Rpc.call_bool(address, LabAbi.encode(config.abis["auction"], signature, []), block, opts)

  defp stocks_uint(config, address, signature, block, opts),
    do:
      Rpc.call_uint(
        address,
        LabAbi.encode(StocksLab.abi!(config, :auction), signature, []),
        block,
        opts
      )

  defp stocks_bool(config, address, signature, block, opts),
    do:
      Rpc.call_bool(
        address,
        LabAbi.encode(StocksLab.abi!(config, :auction), signature, []),
        block,
        opts
      )
end
