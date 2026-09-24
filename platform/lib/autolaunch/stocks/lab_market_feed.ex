defmodule Autolaunch.Stocks.LabMarketFeed do
  @moduledoc """
  Polls the Stocks chain for launches and their auctions: every second on a
  lab, every fifteen seconds on mainnet.

  Two things happen per poll. Each new `launches(id)` record the launchpad holds
  is projected into an `Auction` row when its launcher is a wallet this site's
  accounts hold and no row exists yet. A bounded page of Stocks auction rows is
  then read from their own contracts and the launchpad's lifecycle, and their
  state, minimum and clearing price are refreshed (`Autolaunch.MarketWatch`).
  Changes are broadcast on the shared market topic so open pages reload.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.{LabAbi, LabProjection, MarketWatch, Pool}
  alias Autolaunch.Stocks.{Amounts, Lab}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias Autolaunch.Stocks.LabProjection, as: StocksProjection

  @topic "autolaunch:lab_market"
  @lab_interval 1_000
  @mainnet_interval 15_000
  @actor %System{}
  @new_decimals 18
  @lifecycle_index 11
  @launch_page 200

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
      cursors: %{watch: MarketWatch.new(), next_launch_id: 0},
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
    cursors = state.cursors
    Task.start(fn -> send(parent, {:refreshed, safely(fn -> refresh(cursors) end)}) end)
    {:noreply, %{state | in_flight: true, timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  # A pass reads only part of the auctions, so its readings join the ones
  # earlier passes took; each reading names the block it was taken at.
  def handle_info({:refreshed, {:ok, refresh}}, state) do
    %{head: head, snapshots: readings, changed: changed, cursors: cursors} = refresh
    snapshots = Map.merge(state.snapshots, readings)
    changed_ids = Enum.uniq(changed ++ changed_snapshot_ids(state.snapshots, snapshots))
    state = %{state | cursors: cursors}

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

  # One poll: the launchpad's launch records not yet seen, then this pass's
  # page of Stocks auctions (`Autolaunch.MarketWatch`).
  @doc false
  def refresh(%{watch: watch, next_launch_id: from}) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config, "autolaunch stocks market feed"),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, projected, next_launch_id} <- project_launches(config, block, opts, from),
         {:ok, auctions, next_watch} <- MarketWatch.next(watch, config.chain_id, :stocks),
         {:ok, snapshots, changed} <- refresh_auctions(config, block, opts, auctions) do
      {:ok,
       %{
         head: block,
         snapshots: snapshots,
         changed: projected ++ changed,
         cursors: %{watch: next_watch, next_launch_id: next_launch_id}
       }}
    end
  end

  # Launch ids only grow, so each poll reads only the records after the last
  # one it settled, a bounded number at a time. A record that cannot be read
  # is logged and read again next poll; the ones after it still project. A
  # launchpad with fewer launches than the cursor is a new lab run, read from
  # its first launch.
  defp project_launches(config, block, opts, from) do
    with {:ok, next} <- launchpad_uint(config, "nextLaunchId()", [], block, opts) do
      from = if from > next, do: 0, else: from
      ids = from..min(next - 1, from + @launch_page - 1)//1
      results = Enum.map(ids, &{&1, project_launch(config, &1, block, opts)})

      {:ok, Enum.flat_map(results, &projected/1),
       settled_through(results, from + Enum.count(ids))}
    end
  end

  defp projected({_id, {:ok, nil}}), do: []
  defp projected({_id, {:ok, auction_id}}), do: [auction_id]

  defp projected({id, {:error, reason}}) do
    Logger.warning("memestake market feed skipped launch #{id}: #{inspect(reason)}")
    []
  end

  defp settled_through(results, next_id) do
    case Enum.find(results, &match?({_id, {:error, _reason}}, &1)) do
      {id, _error} -> id
      nil -> next_id
    end
  end

  defp project_launch(config, id, block, opts) do
    with {:ok, record} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [id],
             StocksLabAbi.launch_record_words(),
             block,
             opts
           ),
         {:ok, launch} <- launch_record(record),
         {:ok, nil} <- existing(config.chain_id, launch.auction),
         {:ok, %{id: account_id}} <- creator(launch.auction),
         %{} = lab_stock <- Lab.stock(config, launch.stock) || :unknown_stock,
         {:ok, name} <- Rpc.call_string(launch.new_token, LabAbi.selector("name()"), block, opts),
         {:ok, symbol} <-
           Rpc.call_string(launch.new_token, LabAbi.selector("symbol()"), block, opts),
         {:ok, auction} <-
           StocksProjection.project_observed(%{
             chain_id: config.chain_id,
             auction_address: launch.auction,
             creator_human_account_id: account_id,
             title: name,
             summary: nil,
             token_symbol: String.slice(symbol, 0, 16),
             website: nil,
             image: nil,
             quote_token_address: launch.stock,
             quote_token_symbol: lab_stock.symbol,
             quote_token_decimals: lab_stock.decimals,
             required_currency_raised: Integer.to_string(launch.required),
             state: :created,
             treasury_address: Lab.address!(config, :launchpad)
           }) do
      {:ok, auction.id}
    else
      {:error, reason} -> {:error, reason}
      _skipped -> {:ok, nil}
    end
  end

  # An empty record (a never-used id) has a zero token and is skipped. Word 9
  # is the stock the auction must raise to graduate.
  defp launch_record([launcher, new_token, stock, auction | _rest] = record) do
    with {:ok, launcher} <- Abi.word_address(launcher),
         {:ok, new_token} <- Abi.word_address(new_token),
         {:ok, stock} <- Abi.word_address(stock),
         {:ok, auction} <- Abi.word_address(auction) do
      {:ok,
       %{
         launcher: launcher,
         new_token: new_token,
         stock: stock,
         auction: auction,
         required: Enum.at(record, 9)
       }}
    end
  end

  defp launch_record(_record), do: :error

  defp existing(chain_id, auction_address) do
    case Autolaunch.get_auction_by_chain_address(chain_id, auction_address, actor: @actor) do
      {:ok, nil} -> {:ok, nil}
      {:ok, _row} -> {:ok, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only a launch this server verified from one of its accounts' wallets is a
  # site-created auction; anything else on the launchpad is not listed.
  defp creator(auction) do
    case Autolaunch.get_verified_stocks_launch_by_auction(auction, actor: @actor) do
      {:ok, nil} -> {:ok, :unknown_creator}
      {:ok, %{human_account_id: account_id}} -> {:ok, %{id: account_id}}
      error -> error
    end
  end

  # Each auction is read and written on its own: one that fails is logged and
  # left as it is, and every other auction still refreshes.
  defp refresh_auctions(config, block, opts, auctions) do
    {snapshots, changed} =
      Enum.reduce(auctions, {%{}, []}, fn auction, {snapshots, changed} ->
        case safely(fn -> refresh_auction(config, block, opts, auction) end) do
          {:ok, snapshot, changed_id} ->
            {Map.put(snapshots, snapshot.auction_address, snapshot),
             List.wrap(changed_id) ++ changed}

          # A row whose contract does not exist at this head has no market to
          # read (a launch mined on another lab run, or one a reorg removed).
          {:error, :lab_contract_missing} ->
            {snapshots, changed}

          {:error, reason} ->
            Logger.warning(
              "memestake market feed skipped auction #{auction.auction_address}: #{inspect(reason)}"
            )

            {snapshots, changed}
        end
      end)

    {:ok, snapshots, changed}
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
