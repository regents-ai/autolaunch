defmodule AutolaunchWeb.HomeLive do
  @moduledoc false
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [
      connections_for: 2,
      creator_connections_for: 1,
      current_human_id: 1,
      robinhood?: 1
    ]

  import AutolaunchWeb.Components.MarketCard,
    only: [
      auction_list: 1,
      token_list: 1,
      explore_card: 1,
      backed_card: 1,
      auction_status: 1,
      assign_figure_rates: 1,
      figure_rate: 2
    ]

  import AutolaunchWeb.Components.ChainIcon
  import AutolaunchWeb.Components.HomeProducts, only: [product_cards: 1]
  import AutolaunchWeb.Components.LinkIcon
  import AutolaunchWeb.Components.StockLists
  import AutolaunchWeb.Components.SwapModal
  alias Autolaunch.{CoveredCalls, Exposure, HomeMarket}
  alias AutolaunchWeb.{LabMarket, LiveListings, LiveSettle}
  alias Phoenix.LiveView.AsyncResult

  # What the list shows: auctions, launched tokens, or the covered calls for
  # sale. Tokens choose a type below it, Isolated being the After-hours tokens.
  @lists [auctions: "Auctions", tokens: "Tokens", options: "Options"]
  @token_kinds [
    {"all", "All"},
    {"memestock", "Memestock"},
    {"revstake", "Revstake"},
    {"isolated", "Isolated"}
  ]

  # An auction's status in the filter menu. Each is a set of list options.
  @statuses [new: "All", live: "Live", finished: "Finished"]

  @unfiltered %{q: "", chain: "all", kind: "all", x: false, ens: false, github: false}

  @no_connection %{x: false, ens: false, github: false}

  def mount(_params, _session, socket) do
    offered = %{
      options?: CoveredCalls.Deployment.enabled?(),
      isolated?: Exposure.Deployment.enabled?()
    }

    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/"))
     |> assign(
       market_options: nil,
       trade: nil,
       records: [],
       records_kind: :auction,
       backed: [],
       coming: [],
       creators: %{},
       market_loading: true,
       market_failed: false,
       market_append: false,
       next_cursor: nil,
       has_more: false,
       local_lab: Autolaunch.Lab.test_chain?(),
       listed: nil,
       calls: AsyncResult.loading(),
       isolated: offered.isolated? && Exposure.Listing.fetch(),
       options?: offered.options?,
       isolated?: offered.isolated?,
       lists: lists(offered),
       token_kinds: token_kinds(offered),
       statuses: @statuses,
       unfiltered: @unfiltered,
       no_connection: @no_connection
     )
     |> LiveListings.subscribe()
     |> hear_isolated()
     |> LiveSettle.watch()
     |> LabMarket.assign_robinhood_stale()
     |> assign_figure_rates()}
  end

  def handle_params(params, _uri, socket) do
    options = HomeMarket.options(params)
    list = list(params, socket.assigns)
    first? = is_nil(socket.assigns.market_options)

    socket =
      assign(socket,
        market_options: options,
        list: list,
        token_kind: token_kind(params, options, socket.assigns),
        kind: kind(options),
        tab: tab(options),
        filtered?: filtered?(options),
        filter_active?: filter_active?(options),
        connections: Map.take(options, [:x, :ens, :github]),
        trade: nil
      )

    socket =
      if first?, do: assign(socket, backed: read_backed(), coming: read_coming()), else: socket

    {:noreply,
     case {list, socket.assigns.token_kind} do
       {:options, _kind} -> read_calls(socket, first?)
       {:tokens, "isolated"} -> socket
       _market -> show_market(socket)
     end}
  end

  # The list the address names, among those this site offers.
  defp list(%{"view" => "options"}, %{options?: true}), do: :options
  defp list(%{"view" => "tokens"}, _assigns), do: :tokens
  defp list(_params, _assigns), do: :auctions

  defp token_kind(%{"kind" => "isolated"}, _options, %{isolated?: true}), do: "isolated"
  defp token_kind(_params, options, _assigns), do: options.kind

  defp lists(%{options?: true}), do: @lists
  defp lists(_assigns), do: Keyword.delete(@lists, :options)

  defp token_kinds(%{isolated?: true}), do: @token_kinds
  defp token_kinds(_assigns), do: List.keydelete(@token_kinds, "isolated", 0)

  # The auctions or tokens the options name, read unless they are the ones
  # already shown.
  defp show_market(%{assigns: %{listed: nil}} = socket), do: first_market(socket)

  defp show_market(socket) do
    if Map.drop(socket.assigns.listed, [:display]) ==
         Map.drop(socket.assigns.market_options, [:display]),
       do: socket,
       else: load_market(socket, false)
  end

  # The covered calls for sale, from the market's shared reading. A page that
  # opens on them has them as it arrives, for readers that run no scripts too;
  # a later switch to them, or Try again, reads beside the page.
  defp read_calls(socket, true = _first?), do: put_calls(socket, read_book())

  defp read_calls(socket, false = _first?) do
    socket
    |> assign(:calls, AsyncResult.loading(socket.assigns.calls))
    |> start_async(:home_calls, &read_book/0)
  end

  defp read_book do
    with {:ok, %{markets: [market | _]}} <- CoveredCalls.Deployment.current(),
         do: CoveredCalls.covered_call_book(market.symbol)
  end

  defp put_calls(socket, {:ok, book}),
    do: assign(socket, :calls, AsyncResult.ok(socket.assigns.calls, book))

  defp put_calls(socket, {:error, error}),
    do:
      assign(socket, :calls, AsyncResult.failed(socket.assigns.calls, CoveredCalls.reason(error)))

  # The After-hours tokens are read once for every page (`Exposure.Listing`);
  # an open page hears each new reading.
  defp hear_isolated(%{assigns: %{isolated?: true}} = socket) do
    if connected?(socket), do: Autolaunch.SharedReading.subscribe(Exposure.Listing.key())
    socket
  end

  defp hear_isolated(socket), do: socket

  def handle_event(
        "load-more",
        _params,
        %{assigns: %{market_loading: false, has_more: true}} = socket
      ),
      do: {:noreply, load_market(socket, true)}

  def handle_event("load-more", _params, socket), do: {:noreply, socket}

  def handle_event("open_trade", %{"id" => id}, socket) do
    trade =
      case Enum.find(socket.assigns.records, &(&1.id == id)) do
        %{} = record -> %{record: record}
        _none -> nil
      end

    {:noreply, assign(socket, :trade, trade)}
  end

  def handle_event("open_trade", _params, socket), do: {:noreply, socket}

  def handle_event("close_trade", %{"id" => id}, socket) do
    case socket.assigns.trade do
      %{record: %{id: ^id}} -> {:noreply, assign(socket, :trade, nil)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("close_trade", _params, socket), do: {:noreply, socket}

  def handle_event("retry", _params, socket),
    do: {:noreply, load_market(socket, socket.assigns.market_append)}

  def handle_event("retry_calls", _params, socket), do: {:noreply, read_calls(socket, false)}

  def handle_async(:home_market, {:ok, {:ok, page}}, socket),
    do: {:noreply, put_market(socket, page)}

  def handle_async(:home_market, _failure, socket), do: {:noreply, market_failed(socket)}

  def handle_async(:home_calls, {:ok, result}, socket), do: {:noreply, put_calls(socket, result)}

  def handle_async(:home_calls, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :calls, AsyncResult.failed(socket.assigns.calls, reason))}

  # A reread answers only for the listing it was asked about, at the length it
  # had then; a filter, search or "Load more" since brings its own records.
  def handle_async(:home_reread, {:ok, {options, count, {backed, coming}, {:ok, page}}}, socket) do
    socket = assign(socket, backed: backed, coming: coming)

    if options == socket.assigns.listed and count == length(socket.assigns.records) and
         not socket.assigns.market_loading do
      {:noreply,
       assign(socket,
         records: page.records,
         creators: page.creators,
         next_cursor: page.next_cursor,
         has_more: page.has_more
       )}
    else
      {:noreply, socket}
    end
  end

  # A failed reread leaves the listing the reader already has.
  def handle_async(:home_reread, {:ok, {_options, _count, {backed, coming}, _failure}}, socket),
    do: {:noreply, assign(socket, backed: backed, coming: coming)}

  def handle_async(:home_reread, _failure, socket), do: {:noreply, socket}

  # A new reading of the After-hours tokens.
  def handle_info({:shared_reading, {:exposure_tokens, _id}}, socket),
    do: {:noreply, assign(socket, :isolated, Exposure.Listing.fetch())}

  # The Robinhood notice follows whether the site could read Robinhood.
  def handle_info({:shared_reading, {:chain_head, "robinhood"}}, socket),
    do: {:noreply, LabMarket.robinhood_stale(socket)}

  def handle_info({:autolaunch_listings_changed, _auction_id}, socket),
    do: {:noreply, LiveListings.schedule(socket)}

  # A swap confirmed in a card's swap dialog moved that token's price.
  def handle_info(:reload_pool, socket), do: {:noreply, LiveListings.schedule(socket)}

  def handle_info(:reread_listings, socket),
    do: {:noreply, socket |> LiveListings.taken() |> reread_market()}

  # The cards already shown stay until the new listing arrives and replaces
  # them, so changing a setting never blanks the gallery.
  defp load_market(socket, append?) do
    options = socket.assigns.market_options
    cursor = if append?, do: socket.assigns.next_cursor

    socket
    |> assign(
      listed: options,
      market_loading: true,
      market_failed: false,
      market_append: append?,
      trade: nil
    )
    |> start_async(:home_market, fn -> read_market(options, cursor) end)
  end

  # The page's first listing is read before it is shown, so the coins are in
  # the page as it arrives, for readers that run no scripts too. Later
  # listings load beside the ones already shown.
  defp first_market(socket) do
    socket = assign(socket, market_append: false, listed: socket.assigns.market_options)

    case read_market(socket.assigns.market_options, nil) do
      {:ok, page} -> put_market(socket, page)
      _failure -> market_failed(socket)
    end
  end

  # The "Bid volume" row: up to six launches with the most put in by bidders,
  # whatever the list below shows. Launches nobody has bid on stay out of it.
  defp read_backed do
    case HomeMarket.read(HomeMarket.options(%{"sort" => "volume"}), nil, 6) do
      {:ok, page} -> Enum.filter(page.records, &raised?/1)
      _failure -> []
    end
  end

  # "Coming next": up to three auctions taking bids, the soonest to close
  # first, then those opening soon.
  defp read_coming do
    live = read_records(%{"state" => "active", "sort" => "ending"})
    opening = read_records(%{"state" => "created"})
    Enum.take(live ++ opening, 3)
  end

  defp read_records(params) do
    case HomeMarket.read(HomeMarket.options(params), nil, 3) do
      {:ok, page} -> page.records
      _failure -> []
    end
  end

  defp raised?(%{bid_volume_usd: %Decimal{} = volume}), do: Decimal.gt?(volume, 0)
  defp raised?(_auction), do: false

  defp read_market(options, cursor) do
    with {:ok, page} <- HomeMarket.read(options, cursor) do
      {:ok, Map.put(page, :creators, creator_connections_for(page.records))}
    end
  end

  defp put_market(socket, page) do
    records =
      if socket.assigns.market_append,
        do: Enum.uniq_by(socket.assigns.records ++ page.records, & &1.id),
        else: page.records

    creators =
      if socket.assigns.market_append,
        do: Map.merge(socket.assigns.creators, page.creators),
        else: page.creators

    assign(socket,
      records: records,
      records_kind: kind(socket.assigns.listed),
      creators: creators,
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      market_loading: false,
      market_failed: false
    )
  end

  # A failed "Load more" keeps what is shown; a failed new listing clears the
  # previous one, which no longer matches what was asked for.
  defp market_failed(%{assigns: %{market_append: true}} = socket),
    do: assign(socket, market_loading: false, market_failed: true)

  defp market_failed(socket) do
    assign(socket,
      records: [],
      creators: %{},
      next_cursor: nil,
      has_more: false,
      market_loading: false,
      market_failed: true
    )
  end

  # The records loaded so far, read again in place: the filters, the pages
  # loaded with "Load more" and an open bid form all stay.
  defp reread_market(%{assigns: %{listed: nil}} = socket), do: socket

  defp reread_market(socket) do
    options = socket.assigns.listed
    count = length(socket.assigns.records)

    start_async(socket, :home_reread, fn ->
      result =
        with {:ok, page} <- HomeMarket.reread(options, count) do
          {:ok, Map.put(page, :creators, creator_connections_for(page.records))}
        end

      {options, count, {read_backed(), read_coming()}, result}
    end)
  end

  defp kind(%{view: "tokens"}), do: :token
  defp kind(_options), do: :auction

  attr :patch, :string, required: true
  attr :selected, :boolean, required: true
  attr :label, :string, default: nil, doc: "the option's name when it shows only a logo"
  slot :inner_block, required: true

  # One choice in the filter menu: a tick marks the chosen one in its group.
  defp filter_option(assigns) do
    ~H"""
    <.link
      patch={@patch}
      class="home-filter__option"
      aria-current={if @selected, do: "true"}
      aria-label={@label}
      title={@label}
    >
      <svg class="home-filter__check" viewBox="0 0 16 16" aria-hidden="true">
        <path d="m3 8.5 3.2 3L13 4.5" />
      </svg>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp tab(%{view: "tokens"}), do: :tokens
  defp tab(%{state: "all"}), do: :new
  defp tab(%{state: "active"}), do: :live
  defp tab(%{state: "finished"}), do: :finished
  defp tab(_options), do: nil

  defp tab_options(:new), do: %{view: "auctions", state: "all", sort: "newest"}
  defp tab_options(:live), do: %{view: "auctions", state: "active", sort: "ending"}
  defp tab_options(:finished), do: %{view: "auctions", state: "finished", sort: "newest"}
  defp tab_options(:tokens), do: %{view: "tokens"}

  defp filtered?(options),
    do:
      options.q != "" or options.chain != "all" or options.kind != "all" or options.x or
        options.ens or options.github

  # Whether the filter menu narrows the list: tokens choose their type beside
  # it, not in it.
  defp filter_active?(%{view: "tokens"} = options),
    do: options.chain != "all" or options.x or options.ens or options.github

  defp filter_active?(options),
    do:
      options.chain != "all" or options.kind != "all" or options.state != "all" or options.x or
        options.ens or options.github

  # The After-hours tokens of the series still running, at the top of every
  # token, while the filters and search leave room for them: they are on Base,
  # with no creator.
  defp isolated_lead(
         %{list: :tokens, token_kind: "all", isolated: %{tokens: [_ | _] = tokens}} = assigns
       ) do
    options = assigns.market_options

    if options.chain in ["all", "base"] and !(options.x or options.ens or options.github),
      do: Enum.filter(tokens, &(&1.status != :ended and matches?(&1, options.q))),
      else: []
  end

  defp isolated_lead(_assigns), do: []

  defp matches?(_token, ""), do: true

  defp matches?(token, q),
    do:
      Enum.any?(
        [token.name, token.symbol],
        &String.contains?(String.downcase(&1), String.downcase(q))
      )

  # The way in to launching, beside the way in to backing one. Before
  # launches open it stays in place, switched off, with the reason beside it.
  defp launch_button(assigns) do
    ~H"""
    <.link
      :if={!Autolaunch.Prelaunch.read_only?()}
      navigate="/create"
      class="rg-button rg-button--secondary home-launch"
    >Launch yours</.link>
    <span :if={Autolaunch.Prelaunch.read_only?()} class="home-launch">
      <Regent.Primitives.button variant="secondary" disabled class="create-button">Launch yours</Regent.Primitives.button>
      <small>Opens soon</small>
    </span>
    """
  end

  attr :coming, :list, required: true

  # What a visitor can join next: the auctions taking bids or opening soon,
  # each settling in as the page arrives (`MotionCascade`). While there are
  # none, one quiet line says so; the list below keeps the past ones.
  defp coming_next(assigns) do
    ~H"""
    <section class="home-next" aria-labelledby="home-next-title">
      <h2 id="home-next-title">Coming next</h2>
      <ol
        :if={@coming != []}
        id="home-next-auctions"
        class="home-next__row"
        phx-hook="MotionCascade"
        data-variant={AutolaunchWeb.Motion.standard("grid")}
      >
        <li :for={auction <- @coming}>
          <.link navigate={AutolaunchWeb.Paths.auction(auction)} class="home-next__card">
            <strong>{auction.title}</strong>
            <small>{auction.token_symbol}</small>
            <.auction_status id={"home-next-#{auction.id}"} auction={auction} />
          </.link>
        </li>
      </ol>
      <div :if={@coming == []} class="home-next__empty">
        <svg class="home-next__mark" viewBox="0 0 20 20" aria-hidden="true">
          <circle cx="10" cy="10" r="7.25" /><path d="M10 6v4.25l2.75 1.75" />
        </svg>
        <div>
          <p><strong>No auction is taking bids</strong></p>
          <p>New auctions show here as soon as bidding opens.</p>
        </div>
      </div>
    </section>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :isolated_lead, isolated_lead(assigns))

    ~H"""
    <div class="home-page home-explore-page" id="home-explore">
      <h1 class="visually-hidden">Autolaunch</h1>
      <.product_cards launches_open={!Autolaunch.Prelaunch.read_only?()} />

      <div class="home-toolbar">
        <nav
          id="home-lists"
          class="home-switch"
          aria-label="List"
          phx-hook="MotionTabs"
          data-active={@list}
          data-variant={AutolaunchWeb.Motion.standard("tabs")}
        >
          <span
            id="home-lists-ink"
            class="home-switch__ink"
            data-ink
            aria-hidden="true"
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["style"])}
          ></span>
          <.link
            :for={{list, label} <- @lists}
            patch={list_path(@market_options, list)}
            data-tab={list}
            aria-current={if @list == list, do: "page"}
          >{label}</.link>
        </nav>
        <span :if={@local_lab} class="home-network">
          {Autolaunch.Lab.label()} · test assets
        </span>
        <%!-- Always in the page, so its coming and going never moves Filter, which has the
             keyboard after Clear search. --%>
        <p class="home-search-context" hidden={@market_options.q == "" or !market_list?(assigns)}>
          <span>Results for “{@market_options.q}”</span>
          <button
            type="button"
            phx-click={
              [to: "#home-filters summary"]
              |> Phoenix.LiveView.JS.focus()
              |> Phoenix.LiveView.JS.patch(HomeMarket.path(@market_options, %{q: ""}))
            }
          >
            Clear search
          </button>
        </p>
        <details
          id="home-filters"
          class="home-filter"
          phx-hook=".FilterMenu"
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
          hidden={!market_list?(assigns)}
        >
          <summary>
            Filter<span
              :if={@filter_active? and @market_options.q == ""}
              class="home-filter__active"
              aria-label="Filter active"
            ></span>
          </summary>
          <div class="home-filter__panel" {AutolaunchWeb.Motion.panel("menu")}>
            <div class="home-filter__group" role="group" aria-label="Network">
              <span class="home-filter__label" aria-hidden="true">Network</span>
              <div class="home-filter__row">
                <.filter_option
                  patch={HomeMarket.path(@market_options, %{chain: "all"})}
                  selected={@market_options.chain == "all"}
                >
                  All
                </.filter_option>
                <.filter_option
                  :for={chain <- [:base, :robinhood]}
                  patch={HomeMarket.path(@market_options, %{chain: Atom.to_string(chain)})}
                  selected={@market_options.chain == Atom.to_string(chain)}
                >
                  <.chain_icon chain={chain} />
                </.filter_option>
              </div>
            </div>
            <div :if={@kind == :auction} class="home-filter__group" role="group" aria-label="Status">
              <span class="home-filter__label" aria-hidden="true">Status</span>
              <div class="home-filter__row">
                <.filter_option
                  :for={{status, label} <- @statuses}
                  patch={HomeMarket.path(@market_options, tab_options(status))}
                  selected={@tab == status}
                >
                  {label}
                </.filter_option>
              </div>
            </div>
            <div :if={@kind == :auction} class="home-filter__group" role="group" aria-label="Type">
              <span class="home-filter__label" aria-hidden="true">Type</span>
              <div class="home-filter__row">
                <.filter_option
                  :for={
                    {value, label} <- [
                      {"all", "All"},
                      {"revstake", "Revstake"},
                      {"memestock", "Memestock"}
                    ]
                  }
                  patch={HomeMarket.path(@market_options, %{kind: value})}
                  selected={@market_options.kind == value}
                >
                  {label}
                </.filter_option>
              </div>
            </div>
            <div class="home-filter__group" role="group" aria-label="Creator verified">
              <span class="home-filter__label" aria-hidden="true">Creator verified</span>
              <div class="home-filter__row">
                <.filter_option
                  patch={HomeMarket.path(@market_options, @no_connection)}
                  selected={@connections == @no_connection}
                >
                  Any
                </.filter_option>
                <.filter_option
                  :for={{key, label} <- [x: "X", ens: "ENS", github: "GitHub"]}
                  patch={HomeMarket.path(@market_options, %{@no_connection | key => true})}
                  selected={@connections == %{@no_connection | key => true}}
                  label={label}
                >
                  <.link_icon kind={key} />
                </.filter_option>
              </div>
            </div>
          </div>
        </details>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".FilterMenu">
          export default {
            mounted() {
              this.outside = (event) => {
                if (this.el.open && !this.el.contains(event.target)) this.el.open = false
              }
              this.escape = (event) => {
                if (event.key !== "Escape" || !this.el.open) return
                this.el.open = false
                this.el.querySelector("summary").focus()
              }
              document.addEventListener("pointerdown", this.outside)
              document.addEventListener("keydown", this.escape)
            },
            destroyed() {
              document.removeEventListener("pointerdown", this.outside)
              document.removeEventListener("keydown", this.escape)
            }
          }
        </script>
        <nav class="home-display" aria-label="Display" hidden={!market_list?(assigns)}>
          <.link
            patch={HomeMarket.path(@market_options, %{display: "list"})}
            aria-current={if @market_options.display == "list", do: "page"}
            aria-label="List"
            title="List"
          >
            <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
              <rect x="1" y="2" width="14" height="2.5" rx="1.25" /><rect
                x="1"
                y="6.75"
                width="14"
                height="2.5"
                rx="1.25"
              /><rect x="1" y="11.5" width="14" height="2.5" rx="1.25" />
            </svg>
          </.link>
          <.link
            patch={HomeMarket.path(@market_options, %{display: "grid"})}
            aria-current={if @market_options.display == "grid", do: "page"}
            aria-label="Grid"
            title="Grid"
          >
            <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
              <rect x="1" y="1" width="6" height="6" rx="1.5" /><rect
                x="9"
                y="1"
                width="6"
                height="6"
                rx="1.5"
              /><rect x="1" y="9" width="6" height="6" rx="1.5" /><rect
                x="9"
                y="9"
                width="6"
                height="6"
                rx="1.5"
              />
            </svg>
          </.link>
        </nav>
      </div>

      <nav
        :if={@list == :tokens}
        id="home-kinds"
        class="home-switch home-switch--kinds"
        aria-label="Token type"
        phx-hook="MotionTabs"
        data-active={@token_kind}
        data-variant={AutolaunchWeb.Motion.standard("tabs")}
      >
        <span
          id="home-kinds-ink"
          class="home-switch__ink"
          data-ink
          aria-hidden="true"
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["style"])}
        ></span>
        <.link
          :for={{kind, label} <- @token_kinds}
          patch={kind_path(@market_options, kind)}
          data-tab={kind}
          aria-current={if @token_kind == kind, do: "page"}
        >{label}</.link>
      </nav>

      <section
        :if={@list == :options}
        id="home-calls"
        class="home-market"
        aria-label="Calls for sale"
        aria-busy={to_string(@calls.loading != nil)}
      >
        <.call_list :if={@calls.ok? && !@calls.loading} book={@calls.result} />
        <.list_loading :if={@calls.loading} label="Loading calls" />
        <Regent.Primitives.notice
          :if={@calls.failed && !@calls.loading}
          tone="error"
          class="home-market__error"
        >
          <p>Calls can't be shown right now.</p>
          <Regent.Primitives.button phx-click="retry_calls" variant="secondary">Try again</Regent.Primitives.button>
        </Regent.Primitives.notice>
      </section>

      <section
        :if={@list == :tokens && @token_kind == "isolated"}
        id="home-isolated"
        class="home-market"
        aria-label="Isolated tokens"
        aria-busy={to_string(!@isolated)}
      >
        <.isolated_list :if={@isolated && @isolated.tokens} tokens={@isolated.tokens} />
        <.list_loading :if={!@isolated} label="Loading tokens" />
        <Regent.Primitives.notice
          :if={@isolated && !@isolated.tokens}
          tone="error"
          class="home-market__error"
        >
          <p>Isolated tokens can't be shown right now. They are read again every few minutes.</p>
        </Regent.Primitives.notice>
      </section>

      <section
        :if={market_list?(assigns)}
        id="home-market"
        class="home-market"
        aria-label="Launches"
        aria-busy={to_string(@market_loading)}
      >
        <div
          :if={@market_loading && @records == [] && @market_options.display == "grid"}
          class="home-coin-grid home-skeletons"
          aria-hidden="true"
        >
          <div :for={index <- 1..12} id={"home-skeleton-#{index}"} class="home-skeleton">
            <div class="loading-block home-skeleton__image"></div><div class="loading-block home-skeleton__line">
            </div><div class="loading-block home-skeleton__line home-skeleton__line--short"></div>
          </div>
        </div>
        <p :if={@market_loading} class="visually-hidden" role="status">Loading launches</p>

        <Regent.Primitives.notice
          :if={@robinhood_stale?}
          role="status"
          class="home-market__error"
        >
          <p>
            {if @kind == :token,
              do: "Robinhood could not be read just now, so its tokens show what was last read.",
              else: "Robinhood could not be read just now, so its auctions show what was last read."}
          </p>
        </Regent.Primitives.notice>
        <div
          :if={(@records != [] || @isolated_lead != []) && @market_options.display == "grid"}
          id="home-coin-grid"
          class="home-coin-grid"
          phx-hook="MotionCascade"
          data-variant={AutolaunchWeb.Motion.standard("grid")}
        >
          <.isolated_card :for={token <- @isolated_lead} token={token} />
          <.explore_card
            :for={{record, index} <- Enum.with_index(@records)}
            kind={@records_kind}
            record={record}
            lead={index == 0 && @backed == []}
            creator_connections={connections_for(record, @creators)}
            trade_event="open_trade"
            settle={@settle_labels[record.id]}
            rate={
              figure_rate(@rates, if(@records_kind == :auction, do: record, else: record.auction))
            }
          />
        </div>
        <.auction_list
          :if={
            @market_options.display == "list" && @kind == :auction &&
              (@records != [] || @market_loading)
          }
          creators={@creators}
          records={if @records_kind == :auction, do: @records, else: []}
          rates={@rates}
          loading={@market_loading}
          trade_event="open_trade"
          settle={@settle_labels}
        />
        <.token_list
          :if={
            @market_options.display == "list" && @kind == :token &&
              (@records != [] || @isolated_lead != [] || @market_loading)
          }
          creators={@creators}
          records={if @records_kind == :token, do: @records, else: []}
          rates={@rates}
          loading={@market_loading}
          trade_event="open_trade"
        >
          <:lead_rows>
            <.isolated_rows tokens={@isolated_lead} action />
          </:lead_rows>
        </.token_list>

        <Regent.Primitives.notice :if={@market_failed} tone="error" class="home-market__error">
          <p>
            {if @market_append,
              do: "More launches could not be loaded. The ones shown are still here.",
              else: "Launches can't be shown right now."}
          </p>
          <Regent.Primitives.button phx-click="retry" variant="secondary">Try again</Regent.Primitives.button>
        </Regent.Primitives.notice>
        <div
          :if={!@market_loading && !@market_failed && @records == [] && @isolated_lead == []}
          class="home-empty"
          role="status"
        >
          <%= cond do %>
            <% @filtered? -> %>
              <h2>Nothing matches</h2>
              <p>Try another name, ticker, address or creator, or clear the filters.</p>
              <.link
                patch={HomeMarket.path(@market_options, @unfiltered)}
                class="rg-button rg-button--secondary"
              >Clear filters</.link>
            <% @tab in [:live, :finished, :tokens] -> %>
              <h2>{empty_title(@tab)}</h2>
              <p>{empty_line(@tab)}</p>
              <div class="home-empty__routes">
                <.link
                  :for={{tab, label} <- empty_routes(@tab)}
                  patch={HomeMarket.path(@market_options, tab_options(tab))}
                  class="rg-button rg-button--secondary"
                >{label}</.link>
              </div>
            <% true -> %>
              <h2>No launches yet</h2>
              <p>Be the first: a token you launch opens here for bids.</p>
              <.launch_button />
          <% end %>
        </div>
        <div :if={@has_more && !@market_failed} class="home-load-more">
          <Regent.Primitives.button
            phx-click="load-more"
            disabled={@market_loading}
            variant="secondary"
          >{if @market_loading, do: "Loading…", else: "Load more"}</Regent.Primitives.button>
        </div>
        <p
          :if={!@market_loading && !@market_failed && (@records != [] || @isolated_lead != [])}
          class="home-result-count"
          role="status"
        >
          Showing {count_label(length(@records) + length(@isolated_lead), @records_kind)}{if !@has_more,
            do: " · All results loaded"}
        </p>
      </section>

      <.coming_next coming={@coming} />

      <section :if={@backed != []} class="home-backed" aria-labelledby="home-backed-title">
        <h2 id="home-backed-title">Bid volume</h2>
        <ol class="home-backed__row">
          <li :for={{auction, rank} <- Enum.with_index(@backed, 1)}>
            <.backed_card auction={auction} rank={rank} rate={figure_rate(@rates, auction)} />
          </li>
        </ol>
      </section>
      <.swap_modal
        :if={match?(%{record: %Autolaunch.Token{}}, @trade)}
        id={"home-trade-#{@trade.record.id}"}
        token={@trade.record}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.robinhood_bid_modal
        :if={match?(%{record: %Autolaunch.Auction{}}, @trade) && robinhood?(@trade.record)}
        id={"home-robinhood-bid-#{@trade.record.id}"}
        auction={@trade.record}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.settlement_modal
        :if={match?(%{position: _}, @trade)}
        id={"home-settle-#{@trade.position.id}"}
        position={@trade.position}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.bid_modal
        :if={match?(%{record: %Autolaunch.Auction{}}, @trade) && !robinhood?(@trade.record)}
        id={"home-bid-#{@trade.record.id}"}
        auction={@trade.record}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
    </div>
    """
  end

  # The auctions or launched tokens the site keeps, rather than a list read
  # from Base.
  defp market_list?(%{list: :auctions}), do: true
  defp market_list?(%{list: :tokens, token_kind: kind}), do: kind != "isolated"
  defp market_list?(_assigns), do: false

  # A list keeps the filters that apply to it; its type starts again at All.
  defp list_path(_options, :options), do: "/?view=options"

  defp list_path(options, list),
    do: HomeMarket.path(options, %{view: to_string(list), kind: "all"})

  defp kind_path(_options, "isolated"), do: "/?kind=isolated&view=tokens"
  defp kind_path(options, kind), do: HomeMarket.path(options, %{view: "tokens", kind: kind})

  attr :label, :string, required: true

  defp list_loading(assigns) do
    ~H"""
    <div class="market-list__scroll" aria-hidden="true">
      <span class="loading-block"></span>
    </div>
    <p class="visually-hidden" role="status">{@label}</p>
    """
  end

  defp empty_title(:live), do: "Nothing is live right now."
  defp empty_title(:finished), do: "No auction has finished yet."
  defp empty_title(:tokens), do: "No tokens have launched yet."

  defp empty_line(:live), do: "New auctions show here while bidding is open."
  defp empty_line(:finished), do: "Auctions show here once their bidding closes."
  defp empty_line(:tokens), do: "Tokens appear here once their auction launches."

  # With nothing live, the way on is what already happened: finished auctions
  # and launched tokens.
  defp empty_routes(:live), do: [finished: "See finished auctions", tokens: "See tokens"]
  defp empty_routes(_tab), do: [new: "See every launch"]

  defp count_label(1, :token), do: "1 token"
  defp count_label(count, :token), do: "#{count} tokens"
  defp count_label(1, _kind), do: "1 auction"
  defp count_label(count, _kind), do: "#{count} auctions"
end
