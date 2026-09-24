defmodule Autolaunch.Stocks.LabMarketFeed do
  @moduledoc """
  Keeps the Base Memestake auctions current: every second on a lab, every
  fifteen seconds on mainnet.

  Each poll reads a bounded page of the Memestake auction rows that already
  exist (`Autolaunch.MarketWatch`) from their own contracts and the
  launchpad's lifecycle, and writes back only their state, minimum reached,
  clearing price, bidders' positions and a graduated token's pool price.
  Rows are created elsewhere, by launch discovery and the creator's own
  confirmation, never here. Changes are broadcast on the shared market topic
  so open pages reload.
  """

  use GenServer

  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{LabAbi, LabProjection, MarketWatch, Pool}
  alias Autolaunch.Stocks.{Amounts, Lab}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @topic "autolaunch:lab_market"
  @lab_interval 1_000
  @mainnet_interval 15_000
  @actor %System{}
  @new_decimals 18
  @lifecycle_index 11

  def topic, do: @topic

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))

  @doc "The last accepted per-auction market readings, by lowercase auction address."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(options) do
    state = %{
      pubsub: Keyword.get(options, :pubsub, Autolaunch.PubSub),
      generation: 0,
      head: nil,
      snapshots: %{},
      watch: MarketWatch.new(),
      in_flight: false,
      timer: nil
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       generation: state.generation,
       head: state.head,
       degraded?: false,
       auctions: state.snapshots
     }, state}
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
  # earlier passes took; each reading names the block it was taken at.
  def handle_info({:refreshed, {:ok, refresh}}, state) do
    %{head: head, snapshots: readings, changed: changed, watch: watch} = refresh
    snapshots = Map.merge(state.snapshots, readings)
    changed_ids = Enum.uniq(changed ++ changed_snapshot_ids(state.snapshots, snapshots))
    state = %{state | watch: watch}

    state =
      if changed_ids == [] and state.head == head do
        %{state | in_flight: false}
      else
        generation = state.generation + 1

        Phoenix.PubSub.broadcast(
          state.pubsub,
          @topic,
          {:autolaunch_market_updated,
           %{
             generation: generation,
             auction_ids: changed_ids,
             block_number: head.number,
             block_hash: head.hash
           }}
        )

        %{state | generation: generation, head: head, snapshots: snapshots, in_flight: false}
      end

    {:noreply, schedule(state, interval())}
  end

  def handle_info({:refreshed, {:error, reason}}, state) do
    Logger.warning("memestake market feed skipped a poll: #{inspect(reason)}")
    {:noreply, schedule(%{state | in_flight: false}, interval())}
  end

  defp interval,
    do: if(Autolaunch.Lab.test_chain?(), do: @lab_interval, else: @mainnet_interval)

  # One poll: this pass's page of Memestake auctions (`Autolaunch.MarketWatch`).
  @doc false
  def refresh(watch) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config, "autolaunch stocks market feed"),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, auctions, next_watch} <- MarketWatch.next(watch, config.chain_id, :stocks),
         {:ok, snapshots, changed} <- refresh_auctions(config, block, opts, auctions) do
      {:ok, %{head: block, snapshots: snapshots, changed: changed, watch: next_watch}}
    end
  end

  # Each auction is read and written on its own: one that fails is logged and
  # left as it is, and every other auction still refreshes.
  defp refresh_auctions(config, block, opts, auctions) do
    {snapshots, changed} =
      Enum.reduce(auctions, {%{}, []}, fn auction, collected ->
        result = safely(fn -> refresh_auction(config, block, opts, auction) end)
        collect_reading(result, auction, collected)
      end)

    {:ok, snapshots, changed}
  end

  defp collect_reading({:ok, snapshot, changed_id}, _auction, {snapshots, changed}),
    do: {Map.put(snapshots, snapshot.auction_address, snapshot), List.wrap(changed_id) ++ changed}

  # A row whose contract does not exist at this head has no market to read (a
  # launch mined on another lab run, or one a reorg removed).
  defp collect_reading({:error, :lab_contract_missing}, _auction, collected), do: collected

  defp collect_reading({:error, reason}, auction, collected) do
    Logger.warning(
      "memestake market feed skipped auction #{auction.auction_address}: #{inspect(reason)}"
    )

    collected
  end

  defp refresh_auction(config, block, opts, auction) do
    with {:ok, snapshot} <- market_snapshot(config, block, opts, auction),
         {:ok, changed_id} <- refresh_row(auction, snapshot),
         do: {:ok, snapshot, changed_id}
  end

  defp market_snapshot(config, block, opts, auction) do
    address = auction.auction_address
    decimals = auction.quote_token_decimals

    with :ok <- Autolaunch.LabRpc.ensure_contract(address, block, opts),
         {:ok, start_block} <- auction_uint(config, address, "startBlock()", block, opts),
         {:ok, end_block} <- auction_uint(config, address, "endBlock()", block, opts),
         {:ok, claim_block} <- auction_uint(config, address, "claimBlock()", block, opts),
         {:ok, minimum_reached} <- auction_bool(config, address, "isGraduated()", block, opts),
         {:ok, clearing} <- auction_uint(config, address, "clearingPrice()", block, opts),
         {:ok, raised} <- auction_uint(config, address, "currencyRaised()", block, opts),
         {:ok, remaining} <- auction_uint(config, address, "remainingSupply()", block, opts),
         {:ok, launch_id} <-
           launchpad_uint(config, "launchIdOfAuction(address)", [address], block, opts),
         {:ok, record} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [launch_id],
             StocksLabAbi.launch_record_words(),
             block,
             opts
           ),
         market <- %{end_block: end_block, claim_block: claim_block},
         {:ok, positions} <- positions(config, auction, market, block, opts),
         {:ok, price_quote} <- Pool.stocks_price_quote(config, record, decimals, block, opts) do
      {:ok,
       %{
         auction_id: auction.id,
         auction_address: String.downcase(address),
         state:
           MarketState.observed(
             Enum.at(record, @lifecycle_index),
             block.number,
             start_block,
             end_block
           ),
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
      minimum_reached: snapshot.minimum_reached
    }

    market_changed? =
      auction.state != market.state or auction.current_clearing_price != market.price or
        auction.minimum_reached != market.minimum_reached

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
             %{minimum_reached: market.minimum_reached},
             actor: @actor
           ),
         do: LabProjection.project_graduated_token(row)
  end

  defp launchpad_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :launchpad),
      LabAbi.encode(Lab.abi!(config, :launchpad), signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_words(config, signature, arguments, count, block, opts) do
    Rpc.call_words(
      Lab.address!(config, :launchpad),
      LabAbi.encode(Lab.abi!(config, :launchpad), signature, arguments),
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

  defp changed_snapshot_ids(previous, current) do
    for {address, snapshot} <- current,
        Map.get(previous, address) != snapshot,
        do: snapshot.auction_id
  end

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
