defmodule Autolaunch.Robinhood.MarketFeed do
  @moduledoc """
  Keeps the Robinhood launches in the `auctions` table: every second on the
  local Robinhood lab, every fifteen seconds on the real chain.

  Two things happen per poll, both in a background task:

  - Discovery. Each new `launches(id)` record the Robinhood launchpad holds
    becomes an `Auction` row (kind `:stocks`, the Robinhood chain id), written
    once on the chain-and-address identity with the launch's token, launch id
    and schedule (start and end blocks in the rollup clock): a row that
    already exists is never overwritten. This feed is the only writer that creates Robinhood rows.
    A launch made outside the site is a row too, with origin `:chain`; one
    that matches a review this site stored
    (`Autolaunch.Robinhood.LaunchReview`) has origin `:site` and names that
    review's account as its creator. Only site launches are listed. Launch ids only
    grow, so a cursor remembers the next id to read; a record that cannot be
    read is read again on later polls without holding the cursor back.
  - Refresh. A bounded page of Robinhood rows (`Autolaunch.MarketWatch`) is
    read against the rollup block clock the contracts keep time by
    (`Autolaunch.Robinhood.BlockClock`): state (`Autolaunch.Auction.MarketState`),
    minimum reached and clearing price are written back, and a graduated
    launch's token takes its pool's price; raised amount,
    schedule and a graduated launch's pool, splitter and locker are kept as
    per-auction readings. A launch seen graduated gets its `Token` row
    (`Autolaunch.LabProjection.project_graduated_token/1`, as a Base Memestake
    launch does) in the same transaction as its row.

  This process is its own failure boundary. A Robinhood outage marks its
  readings stale and leaves the stored rows as they are; nothing here touches
  the Base feeds. Changes are broadcast on `topic/0`.
  """

  use GenServer

  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.AuctionTerms
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{LabProjection, MarketWatch}
  alias Autolaunch.Stocks.Amounts

  @topic "autolaunch:robinhood_market"
  @lab_interval 1_000
  @mainnet_interval 15_000
  @launch_page 200
  @token_decimals 18
  @actor %System{}

  def topic, do: @topic

  def start_link(options \\ []) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc """
  The last readings by lowercase auction address, and whether they are stale
  (the last poll could not read the chain). Answered at once.
  """
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc "Asks for a poll now."
  def refresh(server \\ __MODULE__) do
    send(server, :poll)
    :ok
  end

  @impl true
  def init(options) do
    state = %{
      reader: Keyword.get(options, :reader, __MODULE__.Reader),
      pubsub: Keyword.get(options, :pubsub, Autolaunch.PubSub),
      poll?: Keyword.get(options, :poll?, true),
      generation: 0,
      head: nil,
      stale?: false,
      snapshots: %{},
      cursors: %{watch: MarketWatch.new(), next_launch_id: 1, retry_launch_ids: []},
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
       stale?: state.stale?,
       auctions: state.snapshots
     }, state}
  end

  @impl true
  def handle_info(:poll, %{in_flight: false} = state) do
    parent = self()
    %{reader: reader, cursors: cursors} = state
    Task.start(fn -> send(parent, {:refreshed, safely(fn -> poll(reader, cursors) end)}) end)
    {:noreply, %{state | in_flight: true, timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  # A pass reads only part of the auctions, so its readings join the ones
  # earlier passes took; each reading names the block it was taken at.
  def handle_info({:refreshed, {:ok, refresh}}, state) do
    snapshots = Map.merge(state.snapshots, refresh.snapshots)
    changed = Enum.uniq(refresh.changed ++ changed_snapshot_ids(state.snapshots, snapshots))

    state =
      %{state | cursors: refresh.cursors, snapshots: snapshots, in_flight: false}
      |> publish(changed != [] or state.stale? or state.head != refresh.head, %{
        head: refresh.head,
        stale?: false,
        changed: changed
      })

    {:noreply, schedule(state, interval())}
  end

  def handle_info({:refreshed, {:error, reason}}, state) do
    Logger.warning("robinhood market feed could not read the chain: #{inspect(reason)}")

    state =
      publish(%{state | in_flight: false}, not state.stale?, %{
        head: state.head,
        stale?: true,
        changed: []
      })

    {:noreply, schedule(state, interval())}
  end

  defp publish(state, false, _update), do: state

  defp publish(state, true, %{head: head, stale?: stale?, changed: changed}) do
    generation = state.generation + 1

    Phoenix.PubSub.broadcast(
      state.pubsub,
      @topic,
      {:robinhood_market_updated,
       %{
         generation: generation,
         auction_ids: changed,
         stale?: stale?,
         block_number: head && head.number,
         block_hash: head && head.hash
       }}
    )

    %{state | generation: generation, head: head, stale?: stale?}
  end

  @doc false
  def poll(reader, %{watch: watch, next_launch_id: from, retry_launch_ids: retry}) do
    with {:ok, head} <- reader.head(),
         {:ok, discovered, next_launch_id, retry_launch_ids} <-
           discover(reader, head, from, retry),
         {:ok, auctions, next_watch} <- MarketWatch.next(watch, head.chain_id, :stocks) do
      {snapshots, changed} = refresh_auctions(reader, head, auctions)

      {:ok,
       %{
         head: head.block,
         snapshots: snapshots,
         changed: discovered ++ changed,
         cursors: %{
           watch: next_watch,
           next_launch_id: next_launch_id,
           retry_launch_ids: retry_launch_ids
         }
       }}
    end
  end

  # Launch ids start at 1 and only grow, so each poll reads the records after
  # the last one it read, a bounded number at a time. A record that cannot be
  # read is logged and read again on every later poll beside the new ones, so
  # it never holds later launches back. A launchpad with fewer launches than
  # the cursor is a new lab run.
  defp discover(reader, head, from, retry) do
    with {:ok, next} <- reader.next_launch_id(head) do
      {from, retry} = if from > next, do: {1, []}, else: {from, retry}
      page = Enum.to_list(from..min(next - 1, from + @launch_page - 1)//1)

      results =
        Enum.map(retry ++ page, fn id ->
          {id, safely(fn -> discover_launch(reader, head, id) end)}
        end)

      {:ok, Enum.flat_map(results, &discovered/1), from + length(page),
       for({id, result} <- results, unsettled?(result), do: id)}
    end
  end

  defp discover_launch(reader, head, launch_id) do
    with {:ok, launch} <- reader.launch(head, launch_id),
         {:ok, nil} <- existing(head.chain_id, launch.auction),
         {:ok, origin} <- origin(head.chain_id, launch),
         {:ok, auction} <- transaction(fn -> project(head, launch, origin) end) do
      {:ok, auction.id}
    else
      {:ok, :exists} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp discovered({_id, {:ok, nil}}), do: []
  defp discovered({_id, {:ok, auction_id}}), do: [auction_id]

  defp discovered({id, {:error, reason}}) do
    Logger.warning("robinhood market feed skipped launch #{id}: #{inspect(reason)}")
    []
  end

  # A record the auctions table refuses (metadata outside its limits) will
  # never fit, so it is not read again; any other failure is.
  defp unsettled?({:error, %Ash.Error.Invalid{}}), do: false
  defp unsettled?({:error, _reason}), do: true
  defp unsettled?(_result), do: false

  defp existing(chain_id, auction_address) do
    case Autolaunch.get_auction_by_chain_address(chain_id, auction_address, actor: @actor) do
      {:ok, nil} -> {:ok, nil}
      {:ok, _row} -> {:ok, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  # A launch this site prepared is the site's, in the account the review was
  # for; any other launch was only seen on chain.
  defp origin(chain_id, launch) do
    case Autolaunch.matching_robinhood_launch_review(
           chain_id,
           String.downcase(launch.launcher),
           launch.name,
           launch.symbol,
           String.downcase(launch.stock.address),
           Integer.to_string(launch.required),
           Integer.to_string(launch.floor_price_q96),
           actor: @actor
         ) do
      {:ok, %{human_account_id: account_id, telegram: telegram}} ->
        {:ok, {:site, account_id, telegram}}

      {:ok, nil} ->
        {:ok, {:chain, nil, nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp project(head, launch, origin) do
    with {:ok, auction} <- project_auction(head, launch, origin),
         :ok <- LabProjection.project_graduated_token(auction),
         do: {:ok, auction}
  end

  defp project_auction(head, launch, {origin, creator_id, telegram}) do
    Autolaunch.record_launch_auction(
      %{
        kind: :stocks,
        origin: origin,
        chain_id: head.chain_id,
        auction_address: launch.auction,
        creator_human_account_id: creator_id,
        creator_address: String.downcase(launch.launcher),
        title: launch.name,
        summary: launch.description,
        token_symbol: String.slice(launch.symbol, 0, 16),
        website: launch.website,
        telegram: telegram,
        image: launch.image,
        featured: false,
        state:
          MarketState.observed(launch.lifecycle, head.clock, launch.start_block, launch.end_block),
        quote_token_address: launch.stock.address,
        quote_token_symbol: launch.stock.symbol,
        quote_token_decimals: launch.stock.decimals,
        current_clearing_price: "0",
        required_currency_raised: Integer.to_string(launch.required),
        treasury_address: launch.launchpad,
        token_address: launch.token,
        launch_id: launch.launch_id,
        start_block: launch.start_block,
        end_block: launch.end_block
      },
      actor: @actor
    )
  end

  # Each auction is read and written on its own: one that fails is logged and
  # left as it is, and every other auction still refreshes.
  defp refresh_auctions(reader, head, auctions) do
    Enum.reduce(auctions, {%{}, []}, fn auction, collected ->
      result = safely(fn -> refresh_auction(reader, head, auction) end)
      collect_reading(result, auction, collected)
    end)
  end

  defp collect_reading({:ok, reading, changed_ids}, _auction, {snapshots, changed}),
    do: {Map.put(snapshots, reading.auction_address, reading), changed_ids ++ changed}

  defp collect_reading({:error, reason}, auction, collected) do
    Logger.warning(
      "robinhood market feed skipped auction #{auction.auction_address}: #{inspect(reason)}"
    )

    collected
  end

  defp refresh_auction(reader, head, auction) do
    decimals = auction.quote_token_decimals
    price = &Amounts.format_cca_price(&1, decimals, @token_decimals)

    with {:ok, market} <- reader.market(head, auction.auction_address),
         {:ok, terms} <- reader.terms(head, auction, price) do
      observed =
        MarketState.observed(market.lifecycle, head.clock, market.start_block, market.end_block)

      reading = %{
        auction_id: auction.id,
        auction_address: String.downcase(auction.auction_address),
        launch_id: market.launch_id,
        state: MarketState.join(auction.state, observed),
        minimum_reached: market.minimum_reached,
        current_clearing_price:
          Amounts.format_cca_price(market.clearing_price_q96, decimals, @token_decimals),
        currency_raised: Rpc.format_units(market.currency_raised, decimals),
        terms: terms,
        start_block: market.start_block,
        end_block: market.end_block,
        clock: head.clock,
        block_number: head.block.number,
        block_hash: head.block.hash,
        pool: market.pool
      }

      with {:ok, changed_id} <- write(auction, reading) do
        {:ok, reading, Enum.uniq(List.wrap(changed_id) ++ price(reader, head, auction, reading))}
      end
    end
  end

  # A graduated launch's token takes its pool's price on every reading, as a
  # Base Memestake token does. A price that cannot be read is logged and left
  # as it was; the auction's own reading still stands.
  defp price(_reader, _head, _auction, %{pool: nil}), do: []

  defp price(reader, head, auction, reading) do
    with {:ok, quote} <-
           safely(fn -> reader.price_quote(head, reading.pool, auction.quote_token_decimals) end),
         {:ok, changed?} <- LabProjection.project_token_price(auction.id, quote) do
      if changed?, do: [auction.id], else: []
    else
      {:error, reason} ->
        Logger.warning(
          "robinhood market feed could not price #{auction.auction_address}: #{inspect(reason)}"
        )

        []
    end
  end

  defp write(auction, reading) do
    if auction.state == reading.state and
         auction.current_clearing_price == reading.current_clearing_price and
         auction.minimum_reached == reading.minimum_reached and
         not AuctionTerms.raised_changed?(auction, reading.currency_raised) and
         not AuctionTerms.missing?(auction) do
      {:ok, nil}
    else
      transaction(fn -> refresh_row(auction, reading) end)
    end
  end

  # A launch the feed sees graduate becomes a listed token in the same
  # transaction, as a Base Memestake launch does, so the row never says
  # graduated without its token.
  defp refresh_row(auction, reading) do
    with {:ok, row} <-
           Autolaunch.refresh_lab_market_auction(
             auction,
             reading.state,
             reading.current_clearing_price,
             AuctionTerms.fields(reading),
             actor: @actor
           ),
         :ok <- LabProjection.project_graduated_token(row),
         do: {:ok, auction.id}
  end

  defp transaction(write) do
    Ash.transaction(Auction, fn ->
      case write.() do
        {:ok, value} -> value
        {:error, reason} -> Ash.DataLayer.rollback(Auction, reason)
      end
    end)
  end

  defp changed_snapshot_ids(previous, current) do
    for {address, snapshot} <- current,
        Map.get(previous, address) != snapshot,
        do: snapshot.auction_id
  end

  defp interval,
    do: if(Autolaunch.Robinhood.Lab.test_chain?(), do: @lab_interval, else: @mainnet_interval)

  defp schedule(%{poll?: false} = state, _delay), do: state

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

  defmodule Reader do
    @moduledoc """
    The Robinhood chain as the feed reads it, all at one pinned block: the
    head and its rollup clock, one launch record with its token's name,
    symbol and metadata, one auction's market, and its floor price and token
    supply.
    """

    alias Autolaunch.AuctionTerms
    alias Autolaunch.Chain.{Abi, Rpc}
    alias Autolaunch.LabAbi
    alias Autolaunch.Robinhood.{BlockClock, Lab}
    alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
    alias Autolaunch.Stocks.Assets

    # `launches(id)`: launcher, newToken, currency (the stock), auction,
    # startBlock, endBlock, claimBlock, migrationBlock, requiredRaise,
    # floorPriceQ96, lifecycle, ...
    @lifecycle_index 10
    @graduated 2

    def head do
      with {:ok, config} <- Lab.current(),
           opts = Lab.rpc_opts(config),
           {:ok, block} <- Rpc.latest_block(opts),
           {:ok, clock} <- BlockClock.read(block, opts) do
        {:ok,
         %{config: config, opts: opts, chain_id: config.chain_id, block: block, clock: clock}}
      end
    end

    def next_launch_id(head), do: launchpad_uint(head, "nextLaunchId()", [])

    def launch(head, launch_id) do
      with {:ok, words} <- launch_words(head, launch_id),
           {:ok, launcher} <- Abi.word_address(Enum.at(words, 0)),
           {:ok, token} <- Abi.word_address(Enum.at(words, 1)),
           {:ok, stock_address} <- Abi.word_address(Enum.at(words, 2)),
           {:ok, auction} <- Abi.word_address(Enum.at(words, 3)),
           {:ok, stock} <- Assets.fetch(head.chain_id, stock_address),
           {:ok, name} <- token_string(head, token, "name()"),
           {:ok, symbol} <- token_string(head, token, "symbol()"),
           {:ok, metadata} <- metadata(head, token) do
        {:ok,
         %{
           launch_id: launch_id,
           launcher: launcher,
           token: token,
           auction: auction,
           launchpad: Lab.address!(head.config, :stocks_launchpad),
           stock: stock,
           name: name,
           symbol: symbol,
           description: metadata["description"],
           website: metadata["website"],
           image: metadata["image"],
           start_block: Enum.at(words, 4),
           end_block: Enum.at(words, 5),
           required: Enum.at(words, 8),
           floor_price_q96: Enum.at(words, 9),
           lifecycle: Enum.at(words, @lifecycle_index)
         }}
      else
        :error -> {:error, :invalid_chain_response}
        {:error, reason} -> {:error, reason}
      end
    end

    def terms(head, auction, price), do: AuctionTerms.read(auction, price, head.block, head.opts)

    def market(head, auction) do
      with {:ok, launch_id} <- launchpad_uint(head, "launchIdOfAuction(address)", [auction]),
           {:ok, words} <- launch_words(head, launch_id),
           {:ok, minimum_reached} <-
             Rpc.call_bool(auction, auction_call(head, "isGraduated()"), head.block, head.opts),
           {:ok, clearing} <-
             Rpc.call_uint(auction, auction_call(head, "clearingPrice()"), head.block, head.opts),
           {:ok, raised} <-
             Rpc.call_uint(auction, auction_call(head, "currencyRaised()"), head.block, head.opts) do
        {:ok,
         %{
           launch_id: launch_id,
           lifecycle: Enum.at(words, @lifecycle_index),
           start_block: Enum.at(words, 4),
           end_block: Enum.at(words, 5),
           minimum_reached: minimum_reached,
           clearing_price_q96: clearing,
           currency_raised: raised,
           pool: pool(head, words)
         }}
      end
    end

    # A graduated launch's pool (word 11), splitter (word 13) and liquidity
    # position (word 14), all held by the launchpad's locker. `nil` before
    # `migrate` records them.
    defp pool(head, words) do
      if Enum.at(words, @lifecycle_index) == @graduated do
        %{
          pool_id: bytes32(Enum.at(words, 11)),
          token: address(Enum.at(words, 1)),
          stock: address(Enum.at(words, 2)),
          splitter: address(Enum.at(words, 13)),
          lp_token_id: Enum.at(words, 14),
          locker: Lab.address!(head.config, :stocks_locker)
        }
      end
    end

    defp bytes32(word),
      do:
        "0x" <>
          (word |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))

    defp address(word),
      do:
        "0x" <>
          (word |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0"))

    def price_quote(head, pool, stock_decimals) do
      Autolaunch.Pool.pool_price_quote(
        %{
          pool_manager: Lab.address!(head.config, :pool_manager),
          pool_id: pool.pool_id,
          token: pool.token,
          currency: pool.stock,
          currency_decimals: stock_decimals
        },
        head.block,
        head.opts
      )
    end

    # The token's `tokenURI()` is a base64 JSON object holding only the
    # metadata fields the launch filled in.
    defp metadata(head, token) do
      with {:ok, "data:application/json;base64," <> encoded} <-
             token_string(head, token, "tokenURI()"),
           {:ok, json} <- Base.decode64(encoded),
           {:ok, %{} = metadata} <- Jason.decode(json) do
        {:ok, metadata}
      else
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _malformed -> {:error, :invalid_chain_response}
      end
    end

    defp token_string(head, token, signature),
      do: Rpc.call_string(token, LabAbi.selector(signature), head.block, head.opts)

    defp auction_call(head, signature),
      do: LabAbi.encode(Lab.abi!(head.config, :auction), signature, [])

    defp launch_words(head, launch_id) do
      Rpc.call_words(
        Lab.address!(head.config, :stocks_launchpad),
        LabAbi.encode(
          Lab.abi!(head.config, :stocks_launchpad),
          "launches(uint256)",
          [launch_id]
        ),
        head.block,
        RobinhoodLabAbi.launch_record_words(),
        head.opts
      )
    end

    defp launchpad_uint(head, signature, arguments) do
      Rpc.call_uint(
        Lab.address!(head.config, :stocks_launchpad),
        LabAbi.encode(Lab.abi!(head.config, :stocks_launchpad), signature, arguments),
        head.block,
        head.opts
      )
    end
  end
end
