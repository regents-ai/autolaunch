defmodule AutolaunchWeb.RobinhoodAuctionLive do
  @moduledoc """
  One Robinhood Memestake auction, read by its contract address, which
  `AutolaunchWeb.MarketPageLive` hands it from the page address. The page shows the
  auction as the Robinhood market feed stored it (its token's name,
  description, website and image, its state and minimum) with the feed's
  latest reading of what it raised and the chain's clock. It names its
  creator when a signed-up account's wallet launched it, shows how far it is
  toward its minimum and roughly when bidding ends, hands the signed-in
  wallet the bid step, and once the launch has graduated, points at the
  token's own page, where it trades and stakes. When Robinhood cannot be
  read, the page says so and shows what was last read.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1, current_human_id: 1]

  import AutolaunchWeb.Components.MarketCard, only: [detail_card: 1]
  import AutolaunchWeb.Components.LaunchTrust
  import AutolaunchWeb.Components.AuctionBook
  import AutolaunchWeb.Components.AuctionHistory
  import AutolaunchWeb.Components.AuctionPage, only: [headline: 1, details_window: 1]
  import AutolaunchWeb.Components.RaiseProgress
  import AutolaunchWeb.Components.AuctionNext

  alias Autolaunch.{AuctionBook, AuctionSnapshot, AuctionStage, BidReceipt}
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.MarketData
  alias AutolaunchWeb.{LabMarket, Paths, SignedInWallet, UsdValue}
  alias Phoenix.LiveView.AsyncResult

  def mount(_params, _session, socket),
    do:
      {:ok,
       socket
       |> assign(open?: Lab.configured?(), market: LabMarket.subscribe(socket), outbid: nil)
       |> assign(draft_price: nil, scrub_at: nil, checked_bid: nil, check_number: "")
       |> assign_usd_prices()}

  def handle_params(%{"auction" => address}, _uri, socket),
    do: {:noreply, socket |> assign(:auction, address) |> load_launch() |> load_next(true)}

  def handle_event("retry", _params, socket), do: {:noreply, load_launch(socket)}
  def handle_event("retry_history", _params, socket), do: {:noreply, load_history(socket, false)}
  def handle_event("retry_snapshot", _params, socket), do: {:noreply, load_next(socket, false)}

  # The new page's replay of the recorded prices, and its bid lookup.
  def handle_event("scrub", %{"checkpoint" => at}, socket) do
    case Integer.parse(at) do
      {at, ""} when at >= 0 -> {:noreply, assign(socket, :scrub_at, at)}
      _unreadable -> {:noreply, socket}
    end
  end

  def handle_event("scrub_now", _params, socket), do: {:noreply, assign(socket, :scrub_at, nil)}

  def handle_event("check_bid", %{"bid" => number}, socket) do
    %{auction: address, launch: launch} = socket.assigns

    {:noreply,
     socket
     |> assign(:check_number, number)
     |> assign_async(
       :checked_bid,
       fn ->
         with {:ok, bid_id} <- bid_number(number),
              {:ok, receipt} <- BidReceipt.robinhood(address, launch.quote_token_decimals, bid_id) do
           {:ok, %{checked_bid: receipt}}
         end
       end,
       reset: true
     )}
  end

  # The feed read Robinhood again: the stored auction, its reading and its
  # price move together.
  def handle_info({:robinhood_market_updated, _update}, socket),
    do:
      {:noreply,
       socket
       |> assign(:market, LabMarket.snapshot())
       |> reload_launch()
       |> load_history(false)
       |> load_book(false)
       |> load_next(false)}

  # The bid panel found one of the wallet's bids outbid, or none any more.
  def handle_info({:robinhood_outbid, outbid}, socket),
    do: {:noreply, assign(socket, :outbid, outbid)}

  # The bid form's maximum, marked on the new page's chart and ladder.
  def handle_info({:bid_draft_price, price}, socket),
    do: {:noreply, assign(socket, :draft_price, price)}

  def handle_info({:autolaunch_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def render(assigns) do
    assigns =
      assign(assigns,
        usd_rate: usd_rate(assigns.usd_prices, assigns.launch),
        reading: assigns.launch && LabMarket.reading(assigns.market, assigns.auction)
      )

    page(assigns)
  end

  # The new page, in preview at /next/auctions/…: the stage and facts first,
  # the recorded prices over the schedule, the price ladder and a bid lookup,
  # around the same bid panel.
  defp page(%{design: :next} = assigns) do
    ~H"""
    <article
      :if={@open? && @launch}
      id="autolaunch-robinhood-auction"
      class="autolaunch-page auction-page auction-next"
    >
      <header class="autolaunch-heading">
        <.link navigate="/auctions" class="market-back">← Auctions</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{@launch.title} · {@launch.token_symbol}</h1>
        </Regent.Structure.section_bar>
        <p>{network_copy(Lab.test_chain?())}</p>
        <p class="auction-next-preview">
          This is the new auction page.
          <.link navigate={Paths.auction(@launch)}>Open the current page</.link>
        </p>
      </header>
      <.outbid_banner
        :if={@outbid}
        bid_form="autolaunch-robinhood-bid"
        return_to={if @outbid.graduated?, do: @outbid.bid}
      />
      <p :if={@market.robinhood_stale?} class="autolaunch-live-market" role="status">
        Robinhood could not be read just now, so this auction shows what was last read.
      </p>
      <section class="auction-next-overview" aria-label="Where this auction is">
        <p :if={!@snapshot.ok? && @snapshot.loading} class="auction-next-note" role="status">
          Reading the auction from the chain…
        </p>
        <p :if={@snapshot.failed} class="auction-next-note" role="status">
          {if @snapshot.ok?,
            do: "The auction could not be read again just now, so this is the last reading.",
            else: "The auction could not be read from the chain just now."}
          <button type="button" class="auction-next-link" phx-click="retry_snapshot">
            Try again
          </button>
        </p>
        <.stage_rail :if={@snapshot.ok?} stage={@snapshot.result.stage.stage} />
        <.figures
          :if={@snapshot.ok?}
          snapshot={@snapshot.result}
          minimum={required(@launch)}
          raised={@snapshot.result.raised}
          symbol={@launch.quote_token_symbol}
          token_symbol={@launch.token_symbol}
          chain={:robinhood}
          test_chain={Lab.test_chain?()}
        />
        <.facts
          :if={@snapshot.ok?}
          stage={@snapshot.result.stage}
          claim_block={@snapshot.result.blocks.claim}
          block={@snapshot.result.block.number}
        />
      </section>
      <div class="auction-layout">
        <section class="auction-layout__chart" aria-label="Price and schedule">
          <.history_note history={@history} />
          <.filmstrip
            :if={@snapshot.ok? && @history.ok? && @history.result}
            id="robinhood-auction-film"
            snapshot={@snapshot.result}
            points={@history.result.points}
            draft={@draft_price}
            at={@scrub_at}
            symbol={@launch.quote_token_symbol}
            token_symbol={@launch.token_symbol}
          />
        </section>
        <aside class="auction-layout__bid" aria-label="Bid on this auction">
          <.bid_aside
            auction={@auction}
            launch={@launch}
            book={@book}
            account_control={@account_control}
            access_context={@access_context}
            session_lease={@session_lease}
            draft_marker
          />
          <.how_to_bid id="robinhood-auction-how-to-bid" />
        </aside>
        <div class="auction-layout__rest">
          <.ladder
            :if={@snapshot.ok? && @snapshot.result.stage.stage == :open}
            id="robinhood-auction-ladder"
            snapshot={@snapshot.result}
            draft={@draft_price}
            symbol={@launch.quote_token_symbol}
            token_symbol={@launch.token_symbol}
            bid_form="autolaunch-robinhood-bid"
          />
          <.check_bid
            :if={@snapshot.ok?}
            id="robinhood-auction-check-bid"
            checked={@checked_bid}
            number={@check_number}
            wallet={@wallet}
            symbol={@launch.quote_token_symbol}
            token_symbol={@launch.token_symbol}
            claim_block={@snapshot.result.blocks.claim}
          />
          <.auction_activity
            :if={@reading && @history.ok? && @history.result}
            id="robinhood-auction-activity"
            bids={@history.result.bids}
            symbol={@launch.quote_token_symbol}
            block={@reading.clock}
            start_block={@launch.start_block}
            end_block={@launch.end_block}
            chain={:robinhood}
            test_chain={Lab.test_chain?()}
          />
          <.about launch={@launch} usd_rate={@usd_rate} creator_connections={@creator_connections} />
        </div>
      </div>
      <.details launch={@launch} usd_rate={@usd_rate} reading={@reading} />
    </article>
    <.page_states open?={@open?} launch={@launch} launch_failed?={@launch_failed?} auction={@auction} />
    """
  end

  defp page(assigns) do
    ~H"""
    <article
      :if={@open? && @launch}
      id="autolaunch-robinhood-auction"
      class="autolaunch-page auction-page"
    >
      <header class="autolaunch-heading">
        <.link navigate="/auctions" class="market-back">← Auctions</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{@launch.title} · {@launch.token_symbol}</h1>
        </Regent.Structure.section_bar>
        <p>{network_copy(Lab.test_chain?())}</p>
      </header>
      <.outbid_banner
        :if={@outbid}
        bid_form="autolaunch-robinhood-bid"
        return_to={if @outbid.graduated?, do: @outbid.bid}
      />
      <p :if={@market.robinhood_stale?} class="autolaunch-live-market" role="status">
        Robinhood could not be read just now, so this auction shows what was last read.
      </p>
      <p :if={@launch_failed?} class="autolaunch-live-market" role="status">
        This auction could not be read again just now, so it shows what was last read.
      </p>
      <.headline
        record={@launch}
        minimum={required(@launch)}
        usd_rate={@usd_rate}
        details="robinhood-auction-details"
      />
      <div class="auction-layout">
        <section class="auction-layout__chart" aria-label="Price and progress">
          <.history_note history={@history} />
          <.auction_chart
            :if={@reading && @history.ok? && @history.result}
            id="robinhood-auction-chart"
            bids={@history.result.bids}
            points={@history.result.points}
            symbol={@launch.quote_token_symbol}
            token_symbol={@launch.token_symbol}
            usd_rate={@usd_rate}
            raised={@reading.currency_raised}
            block={@reading.clock}
            start_block={@launch.start_block}
            end_block={@launch.end_block}
          />
          <.raise_progress
            :if={@reading}
            id="robinhood-raise-progress"
            state={@launch.state}
            raised={@reading.currency_raised}
            required={required(@launch)}
            symbol={@launch.quote_token_symbol}
            usd_rate={@usd_rate}
            block={@reading.clock}
            start_block={@launch.start_block}
            end_block={@launch.end_block}
            chain={:robinhood}
            test_chain={Lab.test_chain?()}
            bids={@launch.bid_volume && Decimal.to_string(@launch.bid_volume, :normal)}
          />
        </section>
        <aside class="auction-layout__bid" aria-label="Bid on this auction">
          <.bid_aside
            auction={@auction}
            launch={@launch}
            book={@book}
            account_control={@account_control}
            access_context={@access_context}
            session_lease={@session_lease}
          />
        </aside>
        <div class="auction-layout__rest">
          <.auction_book
            :if={@launch.state == :active && @book.ok?}
            id="robinhood-auction-book"
            book={@book.result}
            symbol={@launch.quote_token_symbol}
            usd_rate={@usd_rate}
            color={@launch.image_color}
            bid_form="autolaunch-robinhood-bid"
          />
          <.auction_activity
            :if={@reading && @history.ok? && @history.result}
            id="robinhood-auction-activity"
            bids={@history.result.bids}
            symbol={@launch.quote_token_symbol}
            block={@reading.clock}
            start_block={@launch.start_block}
            end_block={@launch.end_block}
            chain={:robinhood}
            test_chain={Lab.test_chain?()}
          />
          <.about launch={@launch} usd_rate={@usd_rate} creator_connections={@creator_connections} />
        </div>
      </div>
      <.details launch={@launch} usd_rate={@usd_rate} reading={@reading} />
    </article>

    <.page_states open?={@open?} launch={@launch} launch_failed?={@launch_failed?} auction={@auction} />
    """
  end

  attr :auction, :string, required: true
  attr :launch, :map, required: true
  attr :book, Phoenix.LiveView.AsyncResult, required: true
  attr :account_control, :map, required: true
  attr :access_context, :map, required: true
  attr :session_lease, :map, default: nil
  attr :draft_marker, :boolean, default: false

  defp bid_aside(assigns) do
    ~H"""
    <.live_component
      module={AutolaunchWeb.RobinhoodStockBidComponent}
      id="autolaunch-robinhood-bid"
      outbid_banner
      agent_tools
      draft_marker={@draft_marker}
      auction={@auction}
      launch={@launch}
      ended={AutolaunchWeb.RobinhoodStockBidComponent.ended_copy(@launch)}
      token_symbol={@launch.token_symbol}
      stake_path={if @launch.state == :graduated, do: Paths.token(@launch) <> "#stake"}
      book={@book}
      supply={AsyncResult.ok(@launch.token_supply)}
      authenticated={@account_control.kind == :signed_in}
      current_human_id={current_human_id(@access_context)}
      session_lease={@session_lease}
    />
    """
  end

  attr :launch, :map, required: true
  attr :usd_rate, :any, required: true
  attr :creator_connections, :any, required: true

  defp about(assigns) do
    ~H"""
    <section class="auction-info" aria-labelledby="robinhood-auction-info-title">
      <h2 id="robinhood-auction-info-title" class="auction-info__title">About this token</h2>
      <.detail_card
        kind={:auction}
        record={@launch}
      >
        <:price_note>
          <UsdValue.usd
            amount={@launch.current_clearing_price}
            rate={@usd_rate}
            per="per token"
          />
        </:price_note>
      </.detail_card>
      <.launch_trust
        auction={@launch}
        connections={@creator_connections.result}
        token_path={@launch.state == :graduated && Paths.token(@launch)}
      />
      <p
        :if={@launch.state == :graduated}
        id="robinhood-token-link"
        class="autolaunch-live-market"
      >
        This auction launched.
        <.link navigate={Paths.token(@launch)}>
          Open {@launch.token_symbol}, its token, to trade and stake it
        </.link>
      </p>
    </section>
    """
  end

  attr :launch, :map, required: true
  attr :usd_rate, :any, required: true
  attr :reading, :map, default: nil

  defp details(assigns) do
    ~H"""
    <.details_window id="robinhood-auction-details">
      <dl class="autolaunch-live-market" aria-label="Auction facts">
        <div>
          <dt>Minimum to graduate</dt>
          <dd>
            <AutolaunchWeb.TokenDisplay.price
              amount={required(@launch)}
              unit={@launch.quote_token_symbol}
            />
            <UsdValue.usd amount={required(@launch)} rate={@usd_rate} />
          </dd>
        </div>
        <div>
          <dt>Bids are paid in</dt>
          <dd>
            <span class="ticker">USDG</span>, converted into
            <span class="ticker">{@launch.quote_token_symbol}</span>
            inside each bid
          </dd>
        </div>
        <div :if={@reading}>
          <dt>{raised_label(@launch)}</dt>
          <dd>
            <AutolaunchWeb.TokenDisplay.price
              amount={@reading.currency_raised}
              unit={@launch.quote_token_symbol}
            />
            <UsdValue.usd amount={@reading.currency_raised} rate={@usd_rate} />
          </dd>
        </div>
        <div>
          <dt>Auction address</dt>
          <dd class="autolaunch-exact-value">{@launch.auction_address}</dd>
        </div>
      </dl>
    </.details_window>
    """
  end

  attr :open?, :boolean, required: true
  attr :launch, :map, default: nil
  attr :launch_failed?, :boolean, required: true
  attr :auction, :string, default: nil

  defp page_states(assigns) do
    ~H"""
    <section
      :if={!@open? || (!@launch && !@launch_failed?)}
      id="autolaunch-robinhood-auction"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Auction not found</h1>
      </Regent.Structure.section_bar>
      <p :if={!@open?}>Robinhood auctions are not open on this site yet.</p>
      <p :if={@open?}>No Robinhood auction exists at {@auction}.</p>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>

    <section
      :if={@open? && !@launch && @launch_failed?}
      id="autolaunch-robinhood-auction"
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

  # The new page's chain reading: the auction's snapshot with its stage, and
  # the signed-in wallet. The current page reads none of it.
  defp load_next(
         %{assigns: %{design: :next, launch: %{} = launch, auction: address}} = socket,
         reset
       ) do
    socket
    |> assign(
      :wallet,
      SignedInWallet.address(%{
        session_lease: socket.assigns.session_lease,
        current_human_id: current_human_id(socket.assigns.access_context)
      })
    )
    |> assign_async(:snapshot, fn -> snapshot(address, launch) end, reset: reset)
  end

  defp load_next(socket, _reset), do: socket

  defp snapshot(address, launch) do
    with {:ok, snapshot} <- AuctionSnapshot.robinhood(address) do
      pool =
        if launch.state == :graduated,
          do: RobinhoodPool.read(address),
          else: {:error, :not_graduated}

      required = String.to_integer(launch.required_currency_raised)
      stage = AuctionStage.read(launch.state, snapshot, required, pool)
      raised = Rpc.format_units(snapshot.blocks.raised, launch.quote_token_decimals)
      {:ok, %{snapshot: Map.merge(snapshot, %{stage: stage, raised: raised})}}
    end
  end

  defp bid_number(number) do
    case Integer.parse(String.trim(number)) do
      {bid_id, ""} when bid_id >= 0 -> {:ok, bid_id}
      _unreadable -> {:error, :invalid_bid_number}
    end
  end

  defp load_launch(%{assigns: %{open?: false}} = socket),
    do: assign(socket, launch: nil, launch_failed?: false)

  # Another auction's page starts from nothing, so a failed read never leaves
  # the previous auction on screen.
  defp load_launch(socket) do
    socket = socket |> assign(:launch, nil) |> reload_launch() |> load_history(true)
    launch = socket.assigns.launch

    socket
    |> assign_async(
      :creator_connections,
      fn ->
        {:ok,
         %{
           creator_connections:
             launch && connections_for(launch, creator_connections_for([launch]))
         }}
      end,
      reset: true
    )
    |> load_book(true)
  end

  # The price to start buying and the bids around it, read from the auction
  # apart from the page.
  defp load_book(%{assigns: %{auction: nil}} = socket, _reset), do: socket

  defp load_book(socket, reset) do
    auction = socket.assigns.auction

    assign_async(
      socket,
      :book,
      fn -> with {:ok, book} <- AuctionBook.robinhood(auction), do: {:ok, %{book: book}} end,
      reset: reset
    )
  end

  # The auction's confirmed bids and clearing prices, read beside the launch.
  defp load_history(socket, reset) do
    launch = socket.assigns.launch

    assign_async(
      socket,
      :history,
      fn ->
        with %{id: id} <- launch,
             {:ok, bids} <- Autolaunch.auction_bids(id, actor: nil),
             {:ok, points} <- Autolaunch.auction_price_points(id, actor: nil) do
          {:ok, %{history: %{bids: bids, points: points}}}
        else
          nil -> {:ok, %{history: nil}}
          error -> error
        end
      end,
      reset: reset
    )
  end

  defp reload_launch(%{assigns: %{open?: false}} = socket), do: socket

  # A failed re-read keeps the auction already on screen and says so.
  defp reload_launch(socket) do
    case Autolaunch.get_robinhood_auction(socket.assigns.auction, actor: nil, load: [:fdv]) do
      {:ok, launch} -> assign(socket, launch: launch, launch_failed?: false)
      {:error, _reason} -> assign(socket, :launch_failed?, true)
    end
  end

  # The minimum is stored in the stock's smallest unit.
  defp required(launch),
    do:
      launch.required_currency_raised
      |> String.to_integer()
      |> Rpc.format_units(launch.quote_token_decimals)

  # Robinhood's stock prices, read beside the launch so a slow price never
  # holds the auction back.
  defp assign_usd_prices(socket),
    do:
      UsdValue.assign_rate(socket, :usd_prices, :robinhood, fn ->
        {:ok, %{usd_prices: MarketData.prices(:robinhood)}}
      end)

  defp usd_rate(%{result: prices}, %{quote_token_symbol: symbol}),
    do: UsdValue.stock_rate(prices, symbol)

  defp usd_rate(_prices, _launch), do: nil

  # A failed auction's contract still holds what was bid until each bid is
  # returned, so that figure is not what the launch keeps.
  defp raised_label(%{state: :failed, quote_token_symbol: symbol}),
    do: "#{symbol} bid before refunds"

  defp raised_label(%{quote_token_symbol: symbol}), do: "#{symbol} raised"

  defp network_copy(true),
    do: "A Memestake auction on the Robinhood test network. Test assets have no real value."

  defp network_copy(false), do: "A Memestake auction on Robinhood Chain."
end
