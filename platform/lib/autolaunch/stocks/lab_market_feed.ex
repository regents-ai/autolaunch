defmodule Autolaunch.Stocks.LabMarketFeed do
  @moduledoc """
  Keeps the Base Memestock auctions current: every second on a lab, every
  fifteen seconds on mainnet.

  Each poll reads a bounded page of the Memestock auction rows that already
  exist (`Autolaunch.MarketWatch`) from their own contracts and the lifecycle
  of the launchpad their contracts version names, and writes back only their state, minimum reached,
  clearing price, bidders' positions and a graduated token's pool price.
  Rows are created elsewhere, by launch discovery and the creator's own
  confirmation, never here. Each auction's reading is then stored in
  `Autolaunch.SharedReading` (`Autolaunch.MarketReadings`), where every open
  page reads the one copy.
  """

  use GenServer

  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.AuctionSnapshot
  alias Autolaunch.AuctionTerms
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{LabAbi, LabProjection, MarketReadings, MarketWatch, Pool}
  alias Autolaunch.Stocks.{Amounts, Lab}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @feed "stocks"
  @lab_interval 1_000
  @mainnet_interval 15_000
  @actor %System{}
  @new_decimals 18

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))

  @impl true
  def init(_options) do
    MarketReadings.start(@feed, &head/0)
    {:ok, schedule(%{watch: MarketWatch.new(), in_flight: false, timer: nil}, 0)}
  end

  @impl true
  def handle_info(:poll, %{in_flight: false} = state) do
    parent = self()
    watch = state.watch
    Task.start(fn -> send(parent, {:refreshed, safely(fn -> refresh(watch) end)}) end)
    {:noreply, %{state | in_flight: true, timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  # A pass reads only part of the auctions, so its readings join the ones
  # earlier passes stored; each reading names the block it was taken at.
  def handle_info({:refreshed, {:ok, refresh}}, state) do
    MarketReadings.store(@feed, refresh.head, Map.values(refresh.snapshots))
    MarketReadings.read(@feed)
    {:noreply, schedule(%{state | watch: refresh.watch, in_flight: false}, interval())}
  end

  def handle_info({:refreshed, {:error, reason}}, state) do
    Logger.warning("memestock market feed skipped a poll: #{inspect(reason)}")
    MarketReadings.unread(@feed)
    {:noreply, schedule(%{state | in_flight: false}, interval())}
  end

  defp interval,
    do: if(Autolaunch.Lab.test_chain?(), do: @lab_interval, else: @mainnet_interval)

  defp head do
    with {:ok, config} <- Lab.current(), do: Rpc.latest_block(rpc_opts(config))
  end

  defp rpc_opts(config), do: Lab.rpc_opts(config, "autolaunch stocks market feed")

  # One poll: this pass's page of Memestock auctions (`Autolaunch.MarketWatch`),
  # with the auctions whose rows it changed.
  @doc false
  def refresh(watch) do
    with {:ok, config} <- Lab.current(),
         opts <- rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, auctions, next_watch} <- MarketWatch.next(watch, config.chain_id, :stocks),
         {:ok, snapshots, changed} <- refresh_auctions(config, block, opts, auctions) do
      {:ok, %{head: block, snapshots: snapshots, changed: changed, watch: next_watch}}
    end
  end

  # Each auction is read and written on its own: one that fails is logged,
  # marked as not read and left as it is, and every other auction still
  # refreshes. Then the pages of the auctions that were read, apart from their
  # figures and each on its own budget (`AuctionSnapshot.pages/4`): one that
  # cannot be read leaves the page its last reading.
  defp refresh_auctions(config, block, opts, auctions) do
    {read, changed} =
      Enum.reduce(auctions, {[], []}, fn auction, collected ->
        result = safely(fn -> refresh_auction(config, block, opts, auction) end)
        collect_reading(result, auction, collected)
      end)

    pages =
      AuctionSnapshot.pages(
        for({auction, snapshot} <- read, do: {auction, snapshot.state}),
        config,
        block,
        opts
      )

    snapshots =
      Map.new(read, fn {_auction, %{auction_address: address} = snapshot} ->
        {address, Map.put(snapshot, :page, Map.fetch!(pages, address))}
      end)

    {:ok, snapshots, changed}
  end

  defp collect_reading({:ok, snapshot, changed_id}, auction, {read, changed}),
    do: {[{auction, snapshot} | read], List.wrap(changed_id) ++ changed}

  # A row whose contract does not exist at this head has no market to read (a
  # launch mined on another lab run, or one a reorg removed).
  defp collect_reading({:error, :lab_contract_missing}, _auction, collected), do: collected

  defp collect_reading({:error, reason}, auction, collected) do
    Logger.warning(
      "memestock market feed skipped auction #{auction.auction_address}: #{inspect(reason)}"
    )

    MarketReadings.unread_auction(auction.auction_address)
    collected
  end

  # One auction's writes (its positions, its market fields and, on graduation,
  # its token row, then the token's price) land together or not at all: a
  # token that cannot be projected leaves the row as it was, so the next pass
  # sees the graduation again and retries it.
  defp refresh_auction(config, block, opts, auction) do
    with {:ok, snapshot} <- market_snapshot(config, block, opts, auction),
         {:ok, changed_id} <- transaction(fn -> refresh_row(auction, snapshot) end),
         do: {:ok, snapshot, changed_id}
  end

  defp transaction(write) do
    Ash.transaction(Auction, fn ->
      case write.() do
        {:ok, value} -> value
        {:error, reason} -> Ash.DataLayer.rollback(Auction, reason)
      end
    end)
  end

  defp market_snapshot(config, block, opts, auction) do
    address = auction.auction_address
    decimals = auction.quote_token_decimals

    with {:ok, contracts} <- Lab.contracts(config, auction.contracts_version),
         :ok <- Autolaunch.LabRpc.ensure_contract(address, block, opts),
         {:ok, start_block} <- auction_uint(config, address, "startBlock()", block, opts),
         {:ok, end_block} <- auction_uint(config, address, "endBlock()", block, opts),
         {:ok, claim_block} <- auction_uint(config, address, "claimBlock()", block, opts),
         {:ok, minimum_reached} <- auction_bool(config, address, "isGraduated()", block, opts),
         {:ok, clearing} <- auction_uint(config, address, "clearingPrice()", block, opts),
         {:ok, raised} <- auction_uint(config, address, "currencyRaised()", block, opts),
         {:ok, remaining} <- auction_uint(config, address, "remainingSupply()", block, opts),
         {:ok, terms} <-
           AuctionTerms.read(
             auction,
             &Amounts.format_cca_price(&1, decimals, @new_decimals),
             block,
             opts
           ),
         {:ok, launch_id} <-
           launchpad_uint(contracts, "launchIdOfAuction(address)", [address], block, opts),
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
         market <- %{end_block: end_block, claim_block: claim_block},
         {:ok, positions} <- positions(config, auction, market, block, opts),
         {:ok, price_quote} <- Pool.stocks_price_quote(config, record, decimals, block, opts) do
      state = MarketState.observed(record.lifecycle, block.number, start_block, end_block)

      {:ok,
       %{
         auction_id: auction.id,
         auction_address: String.downcase(address),
         state: state,
         current_clearing_price: Amounts.format_cca_price(clearing, decimals, @new_decimals),
         price_quote: price_quote,
         block_number: block.number,
         block_hash: block.hash,
         start_block: start_block,
         end_block: end_block,
         claim_block: claim_block,
         currency_raised: Rpc.format_units(raised, decimals),
         currency_symbol: auction.quote_token_symbol,
         remaining_supply: Rpc.format_units(remaining, @new_decimals),
         terms: terms,
         minimum_reached: minimum_reached,
         positions: positions
       }}
    end
  end

  # After the end block, every site position of this auction is read back from
  # the auction's own `bids(bidId)` so its status follows the contract.
  defp positions(config, auction, market, block, opts) do
    if block.number >= market.end_block do
      with {:ok, rows} <- Autolaunch.LabPositions.positions(auction.id) do
        Autolaunch.LabPositions.read(
          Lab.abi!(config, :auction),
          rows,
          auction.auction_address,
          market,
          block,
          opts
        )
      end
    else
      {:ok, []}
    end
  end

  defp refresh_row(auction, snapshot) do
    market = %{
      state: MarketState.join(auction.state, snapshot.state),
      price: snapshot.current_clearing_price,
      minimum_reached: snapshot.minimum_reached,
      currency_raised: snapshot.currency_raised,
      terms: snapshot.terms
    }

    market_changed? =
      auction.state != market.state or auction.current_clearing_price != market.price or
        auction.minimum_reached != market.minimum_reached or
        AuctionTerms.raised_changed?(auction, market.currency_raised) or
        AuctionTerms.missing?(auction)

    with {:ok, positions_changed?} <- Autolaunch.LabPositions.project(snapshot.positions),
         :ok <- refresh_market(auction, market_changed?, market),
         {:ok, price_changed?} <-
           LabProjection.project_token_price(auction.id, snapshot.price_quote) do
      if market_changed? or positions_changed? or price_changed?,
        do: {:ok, auction.id},
        else: {:ok, nil}
    end
  end

  # A graduation projects the public token row at once, so the pool page exists
  # as soon as the auction row says the launch graduated, and the token's price
  # is the pool's from the same reading.
  defp refresh_market(_auction, false, _market), do: :ok

  defp refresh_market(auction, true, market) do
    with {:ok, row} <-
           Autolaunch.refresh_lab_market_auction(
             auction,
             market.state,
             market.price,
             AuctionTerms.fields(market),
             actor: @actor
           ),
         do: LabProjection.project_graduated_token(row)
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

  defp auction_uint(config, address, signature, block, opts),
    do:
      Rpc.call_uint(
        address,
        LabAbi.encode(Lab.abi!(config, :auction), signature, []),
        block,
        opts
      )

  defp auction_bool(config, address, signature, block, opts),
    do:
      Rpc.call_bool(
        address,
        LabAbi.encode(Lab.abi!(config, :auction), signature, []),
        block,
        opts
      )

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :poll, delay)}
  end

  defp safely(callback) do
    callback.()
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
