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
      assign_figure_rates: 1,
      figure_rate: 2
    ]

  import AutolaunchWeb.Components.ChainIcon
  import AutolaunchWeb.Components.LinkIcon
  import AutolaunchWeb.Components.SwapModal
  alias Autolaunch.{HomeMarket, MarketReadings}
  alias AutolaunchWeb.{LabMarket, LiveListings, LiveSettle}

  # The list's tabs: every launch, the live auctions, the finished ones and the
  # launched tokens. Each is a set of list options.
  @tabs [new: "New", live: "Live", finished: "Finished", tokens: "Tokens"]

  @unfiltered %{q: "", chain: "all", kind: "all", x: false, ens: false, github: false}

  @no_connection %{x: false, ens: false, github: false}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/"))
     |> assign(
       market_options: nil,
       trade: nil,
       records: [],
       records_kind: :auction,
       backed: [],
       creators: %{},
       market_loading: true,
       market_failed: false,
       market_append: false,
       next_cursor: nil,
       has_more: false,
       local_lab: Autolaunch.Lab.test_chain?(),
       tabs: @tabs,
       unfiltered: @unfiltered,
       no_connection: @no_connection
     )
     |> LiveListings.subscribe()
     |> LiveSettle.watch()
     |> LabMarket.assign_robinhood_stale()
     |> assign_figure_rates()}
  end

  def handle_params(params, _uri, socket) do
    options = HomeMarket.options(params)
    previous = socket.assigns.market_options

    socket =
      assign(socket,
        market_options: options,
        kind: kind(options),
        tab: tab(options),
        filtered?: filtered?(options),
        connections: Map.take(options, [:x, :ens, :github]),
        trade: nil
      )

    cond do
      is_nil(previous) -> {:noreply, first_market(socket)}
      Map.drop(previous, [:display]) == Map.drop(options, [:display]) -> {:noreply, socket}
      true -> {:noreply, load_market(socket, false)}
    end
  end

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

  def handle_async(:home_market, {:ok, {:ok, page}}, socket),
    do: {:noreply, put_market(socket, page)}

  def handle_async(:home_market, _failure, socket), do: {:noreply, market_failed(socket)}

  # A reread answers only for the listing it was asked about, at the length it
  # had then; a filter, search or "Load more" since brings its own records.
  def handle_async(:home_reread, {:ok, {options, count, backed, {:ok, page}}}, socket) do
    socket = assign(socket, :backed, backed)

    if options == socket.assigns.market_options and count == length(socket.assigns.records) and
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
  def handle_async(:home_reread, {:ok, {_options, _count, backed, _failure}}, socket),
    do: {:noreply, assign(socket, :backed, backed)}

  def handle_async(:home_reread, _failure, socket), do: {:noreply, socket}

  # The Robinhood notice follows whether its feed could read Robinhood.
  def handle_info({:shared_reading, {:market_feed, "robinhood"}}, socket),
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
    socket = assign(socket, market_append: false, backed: read_backed())

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
      records_kind: kind(socket.assigns.market_options),
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
  defp reread_market(socket) do
    options = socket.assigns.market_options
    count = length(socket.assigns.records)

    start_async(socket, :home_reread, fn ->
      result =
        with {:ok, page} <- HomeMarket.reread(options, count) do
          {:ok, Map.put(page, :creators, creator_connections_for(page.records))}
        end

      {options, count, read_backed(), result}
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

  # The one way in to launching. Before launches open it stays in place,
  # switched off, with the reason beside it.
  defp launch_button(assigns) do
    ~H"""
    <.link
      :if={!Autolaunch.Prelaunch.read_only?()}
      navigate="/create"
      class="rg-button rg-button--primary home-launch"
    >Launch a token</.link>
    <span :if={Autolaunch.Prelaunch.read_only?()} class="home-launch">
      <Regent.Primitives.button disabled class="create-button">Launch a token</Regent.Primitives.button>
      <small>Opens soon</small>
    </span>
    """
  end

  def render(assigns) do
    ~H"""
    <main class="home-page home-explore-page" id="home-explore">
      <header class="home-hero">
        <h1 class="home-hero__title">
          Autolaunch <span>Auctions</span>
        </h1>
        <.launch_button />
      </header>

      <section :if={@backed != []} class="home-backed" aria-labelledby="home-backed-title">
        <h2 id="home-backed-title">Bid volume</h2>
        <ol class="home-backed__row">
          <li :for={{auction, rank} <- Enum.with_index(@backed, 1)}>
            <.backed_card auction={auction} rank={rank} rate={figure_rate(@rates, auction)} />
          </li>
        </ol>
      </section>

      <div class="home-toolbar">
        <nav class="home-tabs" aria-label="Launches">
          <.link
            :for={{tab, label} <- @tabs}
            patch={HomeMarket.path(@market_options, tab_options(tab))}
            aria-current={if @tab == tab, do: "page"}
          >{label}</.link>
        </nav>
        <span :if={@local_lab} class="home-network">
          {Autolaunch.ChainMode.label()} · test assets
        </span>
        <details
          id="home-filters"
          class="home-filter"
          phx-hook=".FilterMenu"
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
        >
          <summary>
            Filter<span
              :if={@filtered? and @market_options.q == ""}
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
            <div class="home-filter__group" role="group" aria-label="Type">
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
        <nav class="home-display" aria-label="Display">
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

      <div
        class="home-search-context"
        data-empty={@market_options.q == ""}
        inert={@market_options.q == ""}
        aria-hidden={to_string(@market_options.q == "")}
      >
        <span>Results for “{@market_options.q}”</span>
        <.link patch={HomeMarket.path(@market_options, %{q: ""})}>Clear search</.link>
      </div>

      <section
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
          :if={@records != [] && @market_options.display == "grid"}
          id="home-coin-grid"
          class="home-coin-grid"
          phx-hook="MotionCascade"
          data-variant={AutolaunchWeb.Motion.standard("grid")}
        >
          <.explore_card
            :for={record <- @records}
            kind={@records_kind}
            record={record}
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
          records={if @records_kind == :auction, do: @records, else: []}
          rates={@rates}
          loading={@market_loading}
          trade_event="open_trade"
          settle={@settle_labels}
        />
        <.token_list
          :if={
            @market_options.display == "list" && @kind == :token &&
              (@records != [] || @market_loading)
          }
          records={if @records_kind == :token, do: @records, else: []}
          rates={@rates}
          loading={@market_loading}
          trade_event="open_trade"
        />

        <Regent.Primitives.notice :if={@market_failed} tone="error" class="home-market__error">
          <p>
            {if @market_append,
              do: "More launches could not be loaded. The ones shown are still here.",
              else: "Launches can't be shown right now."}
          </p>
          <Regent.Primitives.button phx-click="retry" variant="secondary">Try again</Regent.Primitives.button>
        </Regent.Primitives.notice>
        <div
          :if={!@market_loading && !@market_failed && @records == []}
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
          :if={!@market_loading && !@market_failed && @records != []}
          class="home-result-count"
          role="status"
        >
          Showing {count_label(length(@records), @records_kind)}{if !@has_more,
            do: " · All results loaded"}
        </p>
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
        market={MarketReadings.market(@trade.position.auction_address)}
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
    </main>
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
