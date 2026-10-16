defmodule AutolaunchWeb.AuctionLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.MarketCard
  import AutolaunchWeb.Components.LaunchTrust
  import AutolaunchWeb.Components.AuctionBook
  import AutolaunchWeb.Components.AuctionHistory
  import AutolaunchWeb.Components.AuctionPage, only: [details_window: 1]
  import AutolaunchWeb.Components.AuctionNext

  alias Autolaunch.{AuctionBook, AuctionSnapshot, BidReceipt, MarketReadings}
  alias Autolaunch.Lab
  alias AutolaunchWeb.{LabMarket, LiveListings, Paths, UsdValue}
  alias Phoenix.LiveView.AsyncResult

  # The page reads this many of the viewer's own bids from the chain, the newest.
  @receipts_read 10

  # Everything the page shows from the chain that every visitor sees alike is
  # the market feed's one reading of it (`Autolaunch.MarketReadings`): the
  # page reads the chain itself only for the signed-in bidder's own bids.
  def mount(%{"auction_address" => address, "kind" => kind}, _session, socket) do
    feed = MarketReadings.feed(kind)

    {:ok,
     socket
     |> assign(market_address: address, market_feed: feed)
     |> LabMarket.subscribe_auction(address, feed)
     |> assign(head: MarketReadings.head(feed), market_snapshot: MarketReadings.market(address))
     |> assign_snapshot()
     |> LiveListings.subscribe()
     |> assign(
       my_positions: [],
       my_receipts: AsyncResult.ok([]),
       receipts_for: nil,
       positions_unread: false,
       draft_price: nil,
       scrub_at: nil,
       checked_bid: nil,
       check_number: ""
     )}
  end

  # The identifier is read here so a patch to another auction reloads the page
  # instead of keeping the previous record on screen.
  def handle_params(%{"auction_id" => id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:record_id, id)
     |> assign_positions()
     |> load_page(reset: true)
     |> load_receipts()
     |> load_history(reset: true)
     |> load_usd_rate()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket, reset: true)}

  def handle_event("retry_history", _params, socket),
    do: {:noreply, load_history(socket, reset: false)}

  # The replay of the recorded prices, and the bid lookup.
  def handle_event("scrub", %{"checkpoint" => at}, socket) do
    case Integer.parse(at) do
      {at, ""} when at >= 0 -> {:noreply, assign(socket, :scrub_at, at)}
      _unreadable -> {:noreply, socket}
    end
  end

  def handle_event("scrub_now", _params, socket), do: {:noreply, assign(socket, :scrub_at, nil)}

  # The ladder's handle fills in the bid form's maximum; nothing is sent from it.
  def handle_event("price_handle", %{"step" => step}, socket) do
    with %{} = snapshot <- socket.assigns.snapshot,
         {:ok, price} <- handle_price(snapshot, step),
         do:
           send_update(AutolaunchWeb.BidComponent,
             id: bid_form_id(socket.assigns.record_id),
             use_price: price
           )

    {:noreply, socket}
  end

  def handle_event("check_bid", %{"bid" => number}, socket) do
    id = socket.assigns.record_id

    {:noreply,
     socket
     |> assign(:check_number, number)
     |> assign_async(
       :checked_bid,
       fn ->
         with {:ok, bid_id} <- bid_number(number),
              {:ok, %Autolaunch.Auction{} = auction} <- Autolaunch.get_public_auction(id),
              {:ok, receipt} <- BidReceipt.base(auction, bid_id) do
           {:ok, %{checked_bid: receipt}}
         end
       end,
       reset: true
     )}
  end

  # The feed read a new price ladder, schedule or stage for this auction; a
  # new stage reads the viewer's own bids again.
  def handle_info({:shared_reading, {:auction_page, _address}}, socket),
    do: {:noreply, socket |> assign_snapshot() |> load_receipts()}

  # The feed read new figures for this auction and saved them on its row
  # first, so the row, its bids and the viewer's own are read again.
  def handle_info({:shared_reading, {:auction_market, address}}, socket),
    do:
      {:noreply,
       socket
       |> assign(:market_snapshot, MarketReadings.market(address))
       |> assign_positions()
       |> load_page(reset: false)
       |> load_history(reset: false)
       |> load_receipts()}

  # A block went by: the page's clock moves, and a read of the viewer's own
  # bids that failed is tried again. Nothing on the page of a finished auction
  # moves with the block.
  def handle_info({:shared_reading, {:market_head, feed}}, socket) do
    if finished?(socket.assigns.snapshot),
      do: {:noreply, socket},
      else:
        {:noreply,
         socket
         |> assign(:head, MarketReadings.head(feed))
         |> clock_snapshot()
         |> load_receipts()}
  end

  # This auction's saved record changed (its state, bids, minimum, bid terms or
  # treasury report), so the page reads it again in place, with the viewer's own
  # bids; the bid form stays.
  def handle_info({:autolaunch_listings_changed, auction_id}, socket) do
    if auction_id == socket.assigns.record_id,
      do: {:noreply, LiveListings.schedule(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:reread_listings, socket),
    do:
      {:noreply,
       socket
       |> LiveListings.taken()
       |> assign_positions()
       |> load_page(reset: false)
       |> load_history(reset: false)
       |> load_receipts()}

  # A settlement card verified a step, so the bidder's stored positions changed.
  def handle_info({:bid_settlement_changed, _position_id}, socket),
    do: {:noreply, socket |> assign_positions() |> load_receipts()}

  # The bid form's maximum, marked on the chart and ladder.
  def handle_info({:bid_draft_price, price}, socket),
    do: {:noreply, assign(socket, :draft_price, price)}

  def render(assigns) do
    assigns =
      assign(assigns,
        local_lab?: Lab.test_chain?(),
        page_record: page_record(assigns.page),
        page_status: page_status(assigns.page, :error),
        creator_connections: page_connections(assigns.page),
        usd_rate: assigns.usd_rate.result
      )

    assigns =
      assign(assigns,
        graduated_token: page_token(assigns.page),
        bidding_ended?: bidding_ended?(assigns.page_record, assigns.head, assigns.market_snapshot)
      )

    assigns =
      assign(
        assigns,
        :outbid,
        if(bidding_open?(assigns.bidding_ended?), do: outbid(assigns.my_positions, assigns.book))
      )

    assigns =
      assign(assigns,
        receipts_read: @receipts_read,
        receipts_left_out: max(length(onchain_bids(assigns.my_positions)) - @receipts_read, 0)
      )

    page(assigns)
  end

  # The bid form is named after its auction, so a form never carries one
  # auction's review, balance or typed figures over to another.
  defp bid_form_id(auction), do: "autolaunch-bid-#{auction}"

  # The stage and facts first, the recorded prices over the schedule, the
  # price ladder and the bid receipts, around the bid panel.
  defp page(assigns) do
    ~H"""
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-auction-detail"
      class="autolaunch-page auction-page auction-next"
    >
      <header class="autolaunch-heading">
        <.link navigate="/auctions" class="market-back">← Auctions</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{record_label(:auction, @page_record)}</h1>
        </Regent.Structure.section_bar>
      </header>
      <.finished_auction
        :if={@page_record.state == :graduated && @graduated_token}
        auction={@page_record}
        market_cap={@graduated_token.market_cap}
        connections={@creator_connections}
        rate={@usd_rate}
      />
      <.outbid_banner
        :if={@outbid}
        bid_form={bid_form_id(@page_record.id)}
        return_to={if @page_record.minimum_reached, do: "autolaunch-position-#{@outbid.id}"}
      />
      <section class="auction-next-overview" aria-label="Where this auction is">
        <p :if={!@snapshot && !@snapshot_unread?} class="auction-next-note" role="status">
          Reading the auction from the chain…
        </p>
        <p :if={@snapshot_unread?} class="auction-next-note" role="status">
          {if @snapshot,
            do: "The auction could not be read again just now, so this is the last reading.",
            else: "The auction could not be read from the chain just now."}
        </p>
        <.stage_rail :if={@snapshot} stage={@snapshot.stage.stage} facts={@snapshot.stage.facts} />
        <.figures
          :if={@snapshot}
          snapshot={@snapshot}
          auction={@page_record}
          raised={if @page_record.kind == :agent, do: @snapshot.raised}
          symbol={@page_record.quote_token_symbol}
          token_symbol={@page_record.token_symbol}
          chain={:base}
        />
      </section>
      <div class="auction-layout">
        <section class="auction-layout__chart" aria-label="Price and schedule">
          <.history_note history={@history} />
          <.filmstrip
            :if={@snapshot && @history.ok?}
            id="auction-film"
            snapshot={@snapshot}
            points={@history.result.points}
            bids={@history.result.bids}
            draft={@draft_price}
            at={@scrub_at}
            symbol={@page_record.quote_token_symbol}
            token_symbol={@page_record.token_symbol}
          />
        </section>
        <aside class="auction-layout__bid" aria-label="Bid on this auction">
          <.bid_aside
            page_record={@page_record}
            book={@book}
            ended={@bidding_ended?}
            my_positions={@my_positions}
            positions_unread={@positions_unread}
            market_snapshot={@market_snapshot}
            observed={@head}
            account_control={@account_control}
            access_context={@access_context}
            session_lease={@session_lease}
            lab={@local_lab?}
            draft_marker
          />
          <.how_to_bid :if={!@bidding_ended?} id="auction-how-to-bid" />
        </aside>
        <div class="auction-layout__rest">
          <.ladder
            :if={bidding_open?(@bidding_ended?) && @snapshot}
            id="auction-ladder"
            snapshot={@snapshot}
            draft={@draft_price}
            symbol={@page_record.quote_token_symbol}
            token_symbol={@page_record.token_symbol}
            bid_form={bid_form_id(@page_record.id)}
          />
          <section
            :if={@snapshot && @my_receipts.ok? && @my_receipts.result != []}
            id="auction-my-receipts"
            class="auction-next-card"
            aria-labelledby="auction-my-receipts-title"
          >
            <header class="auction-next-card__head">
              <h2 id="auction-my-receipts-title">Your bids, as the auction holds them</h2>
            </header>
            <.receipt
              :for={receipt <- @my_receipts.result}
              id={"auction-receipt-#{receipt.id}"}
              receipt={receipt}
              wallet={@wallet}
              symbol={@page_record.quote_token_symbol}
              token_symbol={@page_record.token_symbol}
              claim_block={@snapshot.blocks.claim}
            />
            <p :if={@receipts_left_out > 0} class="auction-next-note">
              Your {@receipts_read} newest bids. Look up an older one by its number below.
            </p>
          </section>
          <.check_bid
            :if={@snapshot}
            id="auction-check-bid"
            checked={@checked_bid}
            number={@check_number}
            wallet={@wallet}
            symbol={@page_record.quote_token_symbol}
            token_symbol={@page_record.token_symbol}
            claim_block={@snapshot.blocks.claim}
          />
          <.auction_activity
            :if={@head && @market_snapshot && @history.ok?}
            id="auction-activity"
            bids={@history.result.bids}
            symbol={@page_record.quote_token_symbol}
            block={@head.number}
            start_block={@market_snapshot.start_block}
            end_block={@market_snapshot.end_block}
            chain={:base}
            test_chain={@local_lab?}
          />
          <.about
            page_record={@page_record}
            graduated_token={@graduated_token}
            ended={@bidding_ended?}
            usd_rate={@usd_rate}
            creator_connections={@creator_connections}
            lab={@local_lab?}
          />
        </div>
      </div>
      <.details page_record={@page_record} usd_rate={@usd_rate} market_snapshot={@market_snapshot} />
    </article>
    <.page_states page_status={@page_status} record_id={@record_id} />
    """
  end

  attr :page_record, :map, required: true
  attr :book, Phoenix.LiveView.AsyncResult, required: true
  attr :ended, :boolean, required: true
  attr :my_positions, :list, required: true
  attr :positions_unread, :boolean, required: true
  attr :market_snapshot, :map, default: nil
  attr :observed, :any, required: true
  attr :account_control, :map, required: true
  attr :access_context, :map, required: true
  attr :session_lease, :map, default: nil
  attr :lab, :boolean, required: true
  attr :draft_marker, :boolean, default: false

  # The bid form, the bidder's open bids, or their settlement once bidding ends.
  defp bid_aside(assigns) do
    ~H"""
    <section
      :if={Autolaunch.Prelaunch.read_only?()}
      class="prelaunch-actions"
      aria-label="Bidding unavailable"
    >
      <h2>Place a bid</h2>
      <p>Bidding opens soon.</p>
      <Regent.Primitives.button disabled>Place a bid</Regent.Primitives.button>
    </section>
    <.live_component
      :if={!Autolaunch.Prelaunch.read_only?() && !@ended}
      module={AutolaunchWeb.BidComponent}
      id={bid_form_id(@page_record.id)}
      draft_marker={@draft_marker}
      auction={@page_record}
      book={@book}
      authenticated={@account_control.kind == :signed_in}
      current_human_id={current_human_id(@access_context)}
      session_lease={@session_lease}
    />
    <section
      :if={bidding_open?(@ended) && @book.ok? && @my_positions != []}
      id="autolaunch-my-bids"
      class="bid-panel"
      aria-label="Your bids"
    >
      <h3>Your bids on this auction</h3>
      <ul role="list" class="bid-positions">
        <li :for={position <- @my_positions}>
          <.live_component
            module={AutolaunchWeb.OutbidComponent}
            id={"autolaunch-position-#{position.id}"}
            position={position}
            book={@book}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
          />
        </li>
      </ul>
    </section>
    <section
      :if={!Autolaunch.Prelaunch.read_only?() && @ended}
      id="autolaunch-settlement"
      class="bid-panel"
      aria-label="Bidding has ended"
    >
      <AutolaunchWeb.Components.BidForm.title
        id="autolaunch-settlement"
        title="Bidding has ended"
      />
      <p class="bid-ended">{ended_copy(@page_record)}</p>
      <.live_component
        :if={@page_record.state not in [:graduated, :failed]}
        module={AutolaunchWeb.FinishAuctionComponent}
        id="autolaunch-finish"
        auction={@page_record}
        observed={@observed}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <p :if={@account_control.kind != :signed_in} class="bid-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">
          Sign in to see your bids
        </Regent.Primitives.button>
      </p>
      <p
        :if={@account_control.kind == :signed_in && @my_positions == [] && !@positions_unread}
        class="bid-empty"
      >
        You placed no bids on this auction from the wallet you signed in with.
      </p>
      <p :if={@account_control.kind == :signed_in && @positions_unread} class="bid-empty">
        Your bids could not be read just now. Reload the page to try again.
      </p>
      <.live_component
        :for={position <- @my_positions}
        module={AutolaunchWeb.BidSettlementComponent}
        id={"autolaunch-settlement-#{position.id}"}
        position={position}
        market={@market_snapshot}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
    </section>
    <div :if={@lab} id="autolaunch-lab-position"></div>
    <.live_component
      :if={AutolaunchWeb.TestFundsComponent.available?() && @account_control.kind == :signed_in}
      module={AutolaunchWeb.TestFundsComponent}
      id="autolaunch-test-funds"
      current_human_id={current_human_id(@access_context)}
      session_lease={@session_lease}
    />
    """
  end

  attr :page_record, :map, required: true
  attr :graduated_token, :map, default: nil
  attr :ended, :boolean, required: true
  attr :usd_rate, :any, required: true
  attr :creator_connections, :any, required: true
  attr :lab, :boolean, required: true

  defp about(assigns) do
    ~H"""
    <section class="auction-info" aria-labelledby="auction-info-title">
      <h2 id="auction-info-title" class="auction-info__title">About this token</h2>
      <.detail_card
        kind={:auction}
        record={@page_record}
        trade_path={@graduated_token && Paths.token(@page_record)}
        status={settling_status(@page_record, @ended)}
      >
        <:price_note>
          <UsdValue.usd
            amount={@page_record.current_clearing_price}
            rate={@usd_rate}
            per="per token"
          />
        </:price_note>
      </.detail_card>
      <.launch_trust
        auction={@page_record}
        connections={@creator_connections}
        token_path={@graduated_token && Paths.token(@page_record)}
      />
      <.treasury_security
        :if={@page_record.kind == :agent && !@lab}
        report={report(@page_record)}
        surface="auction-detail"
      />
      <.lab_treasury_unavailable
        :if={@page_record.kind == :agent && @lab}
        surface="auction-detail"
      />
    </section>
    """
  end

  attr :page_record, :map, required: true
  attr :usd_rate, :any, required: true
  attr :market_snapshot, :map, default: nil

  defp details(assigns) do
    ~H"""
    <.details_window id="auction-details">
      <.exact_price
        id="auction-exact-price"
        summary="Exact clearing price"
        amount={@page_record.current_clearing_price}
        unit={@page_record.quote_token_symbol}
      />
      <dl class="autolaunch-live-market" aria-label="Auction terms">
        <div>
          <dt>Bids are paid in</dt>
          <dd>
            <span class="ticker">{@page_record.quote_token_symbol}</span>
            <span :if={@page_record.quote_token_decimals}>
              · {@page_record.quote_token_decimals} decimal places
            </span>
          </dd>
        </div>
        <div :if={@page_record.quote_token_address}>
          <dt>Currency address</dt>
          <dd class="autolaunch-exact-value">{@page_record.quote_token_address}</dd>
        </div>
      </dl>
      <dl :if={@market_snapshot} class="autolaunch-live-market" aria-label="Latest reading">
        <div>
          <dt>Read at block</dt><dd>{@market_snapshot.block_number}</dd>
        </div>
        <div>
          <dt>{raised_label(@page_record)}</dt><dd>
            <AutolaunchWeb.TokenDisplay.price
              amount={@market_snapshot.currency_raised}
              fallback="—"
            />
            <UsdValue.usd amount={@market_snapshot.currency_raised} rate={@usd_rate} />
          </dd>
        </div>
        <div>
          <dt>Tokens remaining</dt><dd>
            <AutolaunchWeb.TokenDisplay.price
              amount={@market_snapshot.remaining_supply}
              fallback="—"
            />
          </dd>
        </div>
        <div>
          <dt>Claim block</dt><dd>{@market_snapshot.claim_block}</dd>
        </div>
      </dl>
      <Regent.Primitives.disclosure
        :if={@market_snapshot}
        id="auction-exact-market-amounts"
        summary="Exact market amounts"
      >
        <dl class="autolaunch-live-market">
          <div>
            <dt>{raised_label(@page_record)}</dt><dd class="autolaunch-exact-value">
              {@market_snapshot.currency_raised}
            </dd>
          </div>
          <div>
            <dt>Tokens remaining</dt><dd class="autolaunch-exact-value">
              {@market_snapshot.remaining_supply}
            </dd>
          </div>
        </dl>
      </Regent.Primitives.disclosure>
    </.details_window>
    """
  end

  attr :page_status, :atom, required: true
  attr :record_id, :string, required: true

  defp page_states(assigns) do
    ~H"""
    <p :if={@page_status == :loading} class="autolaunch-page" role="status">Loading…</p>

    <section
      :if={@page_status == :empty}
      id="autolaunch-auction-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Auction not found</h1>
      </Regent.Structure.section_bar>
      <p>No public auction exists at {@record_id}.</p>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>

    <section
      :if={@page_status == :error}
      id="autolaunch-auction-detail"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Auction unavailable</h1>
      </Regent.Structure.section_bar>
      <p>This auction could not be loaded right now.</p>
      <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>
    """
  end

  # The feed's reading of the auction: the price, the ladder, the schedule,
  # the key blocks and the stage, with whether its last attempt failed. An
  # auction with no contract, and one whose feed is not running, has nothing
  # to wait for.
  defp assign_snapshot(%{assigns: %{market_address: address, market_feed: feed}} = socket)
       when is_binary(address) do
    case MarketReadings.page(address) do
      {:ok, %{reading: reading, degraded?: unread?}} -> assign_snapshot(socket, reading, unread?)
      :error -> assign_snapshot(socket, nil, not MarketReadings.running?(feed))
    end
  end

  defp assign_snapshot(socket), do: assign_snapshot(socket, nil, true)

  defp assign_snapshot(socket, snapshot, unread?) do
    socket
    |> assign(snapshot: snapshot, snapshot_unread?: unread?, book: book(snapshot, unread?))
    |> clock_snapshot()
  end

  # The reading names the block its figures were read at; the auction's clock
  # is the feed's newest block.
  defp clock_snapshot(%{assigns: %{snapshot: %{} = snapshot, head: %{number: clock}}} = socket),
    do: assign(socket, :snapshot, %{snapshot | clock: clock})

  defp clock_snapshot(socket), do: socket

  defp finished?(%{stage: %{stage: stage}}), do: stage in [:pool_ready, :failed]
  defp finished?(_no_reading), do: false

  # What the bid form and the bidder's open bids take from the reading.
  defp book(%{} = snapshot, _unread?), do: AsyncResult.ok(AuctionSnapshot.book(snapshot))
  defp book(nil, true), do: AsyncResult.failed(AsyncResult.loading(), :unread)
  defp book(nil, false), do: AsyncResult.loading()

  # The signed-in wallet and its bids as the auction holds them: that
  # bidder's own reading, eight calls to the chain for each bid, so it is
  # bounded. It reads the newest few (`@receipts_read`), and reads them again
  # only when the site's record of one of them changed (placed, outbid,
  # withdrawn, claimed), when the auction moved to another stage, or after a
  # read that failed. Each bid says the block it was read at.
  defp load_receipts(socket) do
    bids = socket.assigns.my_positions |> onchain_bids() |> Enum.take(@receipts_read)

    read_for =
      {Enum.map(bids, &{&1.onchain_bid_id, &1.status, &1.exited_at, &1.claimed_at}),
       stage(socket)}

    socket = assign(socket, :wallet, signed_in_wallet(socket.assigns.access_context))

    if read_for == socket.assigns.receipts_for and !socket.assigns.my_receipts.failed do
      socket
    else
      socket
      |> assign(:receipts_for, read_for)
      |> load_receipts(Enum.map(bids, & &1.onchain_bid_id))
    end
  end

  defp onchain_bids(positions), do: Enum.reject(positions, &is_nil(&1.onchain_bid_id))

  defp stage(%{assigns: %{snapshot: %{stage: %{stage: stage}}}}), do: stage
  defp stage(_no_reading), do: nil

  defp load_receipts(socket, []), do: assign(socket, :my_receipts, AsyncResult.ok([]))

  defp load_receipts(socket, bids) do
    id = socket.assigns.record_id

    assign_async(socket, :my_receipts, fn ->
      with {:ok, %Autolaunch.Auction{} = auction} <- Autolaunch.get_public_auction(id),
           {:ok, receipts} <- receipts(auction, bids) do
        {:ok, %{my_receipts: receipts}}
      end
    end)
  end

  defp receipts(auction, bids) do
    Enum.reduce_while(bids, {:ok, []}, fn bid, {:ok, found} ->
      with {:ok, bid_id} <- bid_number(bid),
           {:ok, receipt} <- BidReceipt.base(auction, bid_id) do
        {:cont, {:ok, found ++ [receipt]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp bid_number(number) do
    case Integer.parse(String.trim(number)) do
      {bid_id, ""} when bid_id >= 0 -> {:ok, bid_id}
      _unreadable -> {:error, :invalid_bid_number}
    end
  end

  defp load_page(socket, reset: reset) do
    id = socket.assigns.record_id
    assign_async(socket, :page, fn -> load_auction_page_with_token(id) end, reset: reset)
  end

  # The auction's confirmed bids and clearing prices, read apart from the page.
  defp load_history(socket, reset: reset) do
    id = socket.assigns.record_id

    assign_async(
      socket,
      :history,
      fn ->
        with {:ok, bids} <- Autolaunch.auction_bids(id, actor: nil),
             {:ok, points} <- Autolaunch.auction_price_points(id, actor: nil) do
          {:ok, %{history: %{bids: bids, points: points}}}
        end
      end,
      reset: reset
    )
  end

  defp bidding_open?(bidding_ended?), do: !Autolaunch.Prelaunch.read_only?() && !bidding_ended?

  # The first of the bidder's still-open bids that the price has passed.
  defp outbid(positions, %{ok?: true, result: book}) do
    Enum.find(positions, fn
      %{status: "active", max_price: max_price, auction: %{quote_token_decimals: decimals}} ->
        {:ok, price_q96} = Autolaunch.BidActions.price_q96(max_price, decimals)
        AuctionBook.standing(price_q96, book) == :outbid

      _settled ->
        false
    end)
  end

  defp outbid(_positions, _book), do: nil

  # The dollar price of the auction's currency, read apart from the page so a
  # slow price never holds the auction back and a market update never reads it
  # again.
  defp load_usd_rate(socket) do
    id = socket.assigns.record_id

    UsdValue.assign_rate(socket, :usd_rate, :base, fn ->
      with {:ok, uuid} <- Ash.Type.UUID.cast_input(id, []),
           {:ok, %Autolaunch.Auction{} = auction} <- Autolaunch.get_public_auction(uuid) do
        {:ok, %{usd_rate: UsdValue.rate(auction)}}
      else
        _missing -> {:error, :no_auction}
      end
    end)
  end

  # The signed-in wallet's own positions on this auction, for settlement once
  # bidding has ended. A read that fails says so rather than showing no bids.
  defp assign_positions(socket) do
    with actor when not is_nil(actor) <- human_actor(socket.assigns.access_context),
         {:ok, uuid} <- Ash.Type.UUID.cast_input(socket.assigns.record_id, []) do
      wallet = signed_in_wallet(socket.assigns.access_context)

      case Autolaunch.list_wallet_bid_positions(wallet, actor: actor) do
        {:ok, positions} ->
          assign(socket,
            my_positions: Enum.filter(positions, &(&1.auction_id == uuid)),
            positions_unread: false
          )

        {:error, _reason} ->
          assign(socket, my_positions: [], positions_unread: true)
      end
    else
      _signed_out -> assign(socket, my_positions: [], positions_unread: false)
    end
  end

  # Between the end block and the feed's next reading the record still says
  # active; the page knows bidding is over and says so.
  defp settling_status(%{state: :active}, true), do: "Waiting to finish"
  defp settling_status(_record, _bidding_ended?), do: nil

  defp bidding_ended?(%{state: state}, _head, _market)
       when state in [:ended, :graduated, :failed],
       do: true

  defp bidding_ended?(_record, %{number: block}, %{end_block: end_block}),
    do: block >= end_block

  defp bidding_ended?(_record, _head, _market), do: false

  defp ended_copy(%{state: :graduated, quote_token_symbol: symbol}),
    do:
      "The auction raised its minimum. Bidders can claim the tokens their bids bought and withdraw any unspent #{symbol}."

  defp ended_copy(%{state: :failed, quote_token_symbol: symbol}),
    do:
      "The auction did not raise its minimum. Every bidder can withdraw their whole bid in #{symbol}."

  defp ended_copy(%{minimum_reached: true, quote_token_symbol: symbol}),
    do:
      "Bidding has ended and the auction raised its minimum. Its trading pool opens once the auction is finished. Bidders can withdraw any unspent #{symbol} and, once claims open, claim the tokens their bids bought."

  defp ended_copy(%{quote_token_symbol: symbol}),
    do:
      "Bidding has ended. If the final count stays below the minimum, every bidder can withdraw their whole bid in #{symbol}; if it reached the minimum, the trading pool opens once the auction is finished."

  # The auction with its FDV for the headline, and a graduated auction's token
  # row, when it exists, so the page can point at the pool that auction
  # graduated into.
  defp load_auction_page_with_token(id) do
    with {:ok, %{page: page}} <- load_auction_page(id),
         {:ok, record} <- with_fdv(page.record) do
      {:ok, %{page: %{page | record: record} |> Map.put(:token, graduated_token(record))}}
    end
  end

  defp with_fdv(nil), do: {:ok, nil}
  defp with_fdv(record), do: Ash.load(record, [:fdv], actor: nil, reuse_values?: true)

  defp graduated_token(%{state: :graduated, id: auction_id}) do
    case Autolaunch.get_public_token_by_auction(auction_id, load: [:market_cap]) do
      {:ok, token} -> token
      {:error, _reason} -> nil
    end
  end

  defp graduated_token(_record), do: nil

  # A failed auction's currency is refunded from the block it failed, so what
  # its contract still holds is what was bid, not what the launch keeps.
  defp raised_label(%{state: :failed, quote_token_symbol: symbol}),
    do: "#{symbol} bid before refunds"

  defp raised_label(%{quote_token_symbol: symbol}), do: "#{symbol} raised"

  defp page_token(%{ok?: true, result: %{token: token}}), do: token
  defp page_token(_page), do: nil
end
