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
      assign_figure_rates: 1,
      figure_rate: 2
    ]

  import AutolaunchWeb.Components.ChainIcon
  import AutolaunchWeb.Components.LinkIcon
  import AutolaunchWeb.Components.Opening, only: [welcome: 1]
  import AutolaunchWeb.Components.SwapModal
  import AutolaunchWeb.Components.AuctionStats
  alias Autolaunch.HomeMarket
  alias AutolaunchWeb.{LabMarket, LiveListings}

  @no_connection %{x: false, ens: false, github: false}

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       market_options: nil,
       trade: nil,
       records: [],
       records_kind: :auction,
       creators: %{},
       market: LabMarket.subscribe(socket),
       market_loading: true,
       market_failed: false,
       market_append: false,
       next_cursor: nil,
       has_more: false,
       local_lab: Autolaunch.Lab.test_chain?()
     )
     |> LiveListings.subscribe()
     |> assign_auction_stats()
     |> assign_figure_rates()}
  end

  def handle_params(params, _uri, socket) do
    options = HomeMarket.options(params)
    previous = socket.assigns.market_options
    socket = assign(socket, market_options: options, search_query: options.q, trade: nil)

    if previous && Map.drop(previous, [:display]) == Map.drop(options, [:display]) do
      {:noreply, socket}
    else
      {:noreply, load_market(socket, false)}
    end
  end

  def handle_event("search", params, socket) do
    {:noreply,
     push_patch(socket,
       to: HomeMarket.path(socket.assigns.market_options, %{q: Map.get(params, "q", "")})
     )}
  end

  # Results follow the header field as it is typed, without a history step per pause.
  def handle_event("type_search", params, socket) do
    {:noreply,
     push_patch(socket,
       to: HomeMarket.path(socket.assigns.market_options, %{q: Map.get(params, "q", "")}),
       replace: true
     )}
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

  def handle_async(:home_market, {:ok, {:ok, page}}, socket) do
    records =
      if socket.assigns.market_append,
        do: Enum.uniq_by(socket.assigns.records ++ page.records, & &1.id),
        else: page.records

    creators =
      if socket.assigns.market_append,
        do: Map.merge(socket.assigns.creators, page.creators),
        else: page.creators

    {:noreply,
     assign(socket,
       records: records,
       records_kind: kind(socket.assigns.market_options),
       creators: creators,
       next_cursor: page.next_cursor,
       has_more: page.has_more,
       market_loading: false,
       market_failed: false
     )}
  end

  # A failed "Load more" keeps what is shown; a failed new listing clears the
  # previous one, which no longer matches what was asked for.
  def handle_async(:home_market, _failure, %{assigns: %{market_append: true}} = socket),
    do: {:noreply, assign(socket, market_loading: false, market_failed: true)}

  def handle_async(:home_market, _failure, socket) do
    {:noreply,
     assign(socket,
       records: [],
       creators: %{},
       next_cursor: nil,
       has_more: false,
       market_loading: false,
       market_failed: true
     )}
  end

  # A reread answers only for the listing it was asked about, at the length it
  # had then; a filter, search or "Load more" since brings its own records.
  def handle_async(:home_reread, {:ok, {options, count, {:ok, page}}}, socket) do
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
  def handle_async(:home_reread, _failure, socket), do: {:noreply, socket}

  # The Robinhood notice follows whether its feed could read Robinhood.
  def handle_info({:autolaunch_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def handle_info({:robinhood_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def handle_info({:autolaunch_listings_changed, _auction_id}, socket),
    do: {:noreply, LiveListings.schedule(socket)}

  def handle_info(:reread_listings, socket),
    do: {:noreply, socket |> LiveListings.taken() |> reread_market() |> assign_auction_stats()}

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
    |> start_async(:home_market, fn ->
      with {:ok, page} <- HomeMarket.read(options, cursor) do
        {:ok, Map.put(page, :creators, creator_connections_for(page.records))}
      end
    end)
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

      {options, count, result}
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

  defp network_label("base"), do: "Base"
  defp network_label("robinhood"), do: "Robinhood"
  defp network_label(_), do: "Base + Robinhood"

  def render(assigns) do
    assigns =
      assign(assigns,
        kind: kind(assigns.market_options),
        listed?: assigns.records != [],
        no_connection: @no_connection,
        connections: Map.take(assigns.market_options, [:x, :ens, :github])
      )

    ~H"""
    <main class="home-page home-explore-page" id="home-explore">
      <.welcome :if={Autolaunch.Prelaunch.read_only?()} />
      <.auction_stats revstake={@revstake_stats} memestake={@memestake_stats} />
      <header class="home-heading">
        <div class="home-heading__discovery">
          <h1 id="home-explore-title">Explore</h1>
          <nav class="home-kind-toggle" aria-label="Explore auctions or launched tokens">
            <.link
              patch={HomeMarket.path(@market_options, %{view: "auctions", state: "all"})}
              aria-current={if @kind == :auction, do: "page"}
            >Auctions</.link>
            <span aria-hidden="true">|</span>
            <.link
              patch={HomeMarket.path(@market_options, %{view: "tokens", state: "all"})}
              aria-current={if @kind == :token, do: "page"}
            >Tokens</.link>
          </nav>
          <.link
            :if={@kind == :auction}
            navigate={~p"/auctions"}
            class="home-heading__all"
          >Search all auctions</.link>
          <.link :if={@kind == :token} navigate={~p"/tokens"} class="home-heading__all">
            Search all tokens
          </.link>
        </div>
        <span class="home-network" title="The network these listings belong to">
          <span aria-hidden="true" class="home-network__dot"></span>
          {if @local_lab,
            do: "#{Autolaunch.ChainMode.label()} · test assets",
            else: network_label(@market_options.chain)}
        </span>
      </header>

      <div class="home-toolbar">
        <nav :if={@kind == :auction} class="home-sort" aria-label="Sort auctions">
          <.link
            :for={
              {value, label} <- [{"newest", "Recent"}, {"ending", "Closing"}, {"volume", "Highest"}]
            }
            patch={HomeMarket.path(@market_options, %{sort: value})}
            aria-current={if @market_options.sort == value, do: "page"}
          >{label}</.link>
        </nav>
        <nav class="home-display" aria-label="Display">
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
          <.link
            patch={HomeMarket.path(@market_options, %{display: "table"})}
            aria-current={if @market_options.display == "table", do: "page"}
            aria-label="Table"
            title="Table"
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
        </nav>
        <details
          id="home-filters"
          class="home-filter"
          phx-hook=".FilterMenu"
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
        >
          <summary>
            Filter<span
              :if={
                @market_options.state != "all" or @market_options.chain != "all" or
                  @market_options.kind != "all" or @market_options.x or @market_options.ens or
                  @market_options.github
              }
              class="home-filter__active"
              aria-label="Filter active"
            ></span>
          </summary>
          <div class="home-filter__panel">
            <div :if={@kind == :auction} class="home-filter__group" role="group" aria-label="Status">
              <span class="home-filter__label" aria-hidden="true">Status</span>
              <.filter_option
                :for={
                  {value, label} <- [
                    {"all", "All"},
                    {"created", "Opening soon"},
                    {"active", "Live"},
                    {"ended", "Waiting to finish"},
                    {"failed", "Failed"},
                    {"graduated", "Launched"}
                  ]
                }
                patch={HomeMarket.path(@market_options, %{state: value})}
                selected={@market_options.state == value}
              >
                {label}
              </.filter_option>
            </div>
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
                      {"memestake", "Memestake"}
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
      </div>

      <p :if={@market_options.sort == "volume"} class="home-search-context">
        Confirmed bids, valued at the latest available currency price. Auctions awaiting indexing or a price appear last.
      </p>
      <p :if={@market_options.sort == "ending"} class="home-search-context">
        Live auctions, ordered by estimated closing time. Timing follows each network's block clock.
      </p>
      <div :if={@market_options.q != ""} class="home-search-context">
        <span>Results for “{@market_options.q}”</span>
        <.link patch={HomeMarket.path(@market_options, %{q: ""})}>Clear search</.link>
      </div>

      <section
        id="home-market"
        class="home-market"
        aria-labelledby="home-explore-title"
        aria-busy={to_string(@market_loading)}
      >
        <div
          :if={@market_loading && !@listed?}
          class="home-coin-grid home-skeletons"
          aria-hidden="true"
        >
          <div :for={index <- 1..12} id={"home-skeleton-#{index}"} class="home-skeleton">
            <div class="home-skeleton__image"></div><div class="home-skeleton__line"></div><div class="home-skeleton__line home-skeleton__line--short">
            </div>
          </div>
        </div>
        <p :if={@market_loading} class="visually-hidden" role="status">Loading coins</p>

        <Regent.Primitives.notice
          :if={@market.robinhood_stale?}
          role="status"
          class="home-market__error"
        >
          <p>
            {if @kind == :token,
              do: "Robinhood could not be read just now, so its tokens show what was last read.",
              else: "Robinhood could not be read just now, so its auctions show what was last read."}
          </p>
        </Regent.Primitives.notice>
        <div :if={@listed? && @market_options.display == "grid"} class="home-coin-grid">
          <.explore_card
            :for={record <- @records}
            kind={@records_kind}
            record={record}
            creator_connections={connections_for(record, @creators)}
            trade_event="open_trade"
            rate={
              figure_rate(@rates, if(@records_kind == :auction, do: record, else: record.auction))
            }
          />
        </div>
        <.auction_list
          :if={@listed? && @market_options.display == "table" && @records_kind == :auction}
          records={@records}
          rates={@rates}
        />
        <.token_list
          :if={@listed? && @market_options.display == "table" && @records_kind == :token}
          records={@records}
          rates={@rates}
        />

        <Regent.Primitives.notice :if={@market_failed} tone="error" class="home-market__error">
          <p>
            {if @market_append,
              do: "More coins could not be loaded. Your current results are still here.",
              else: "Listings are unavailable right now."}
          </p>
          <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
        </Regent.Primitives.notice>
        <div
          :if={!@market_loading && !@market_failed && !@listed?}
          class="home-empty"
          role="status"
        >
          <h2>
            {if @market_options.q != "" or
                  (@market_options.state != "all" or @market_options.chain != "all" or
                     @market_options.kind != "all" or @market_options.x or @market_options.ens or
                     @market_options.github),
                do: "No matching coins",
                else: "No coins in this category yet"}
          </h2>
          <p>
            {if @market_options.q != "" or
                  (@market_options.state != "all" or @market_options.chain != "all" or
                     @market_options.kind != "all" or @market_options.x or @market_options.ens or
                     @market_options.github),
                do: "Try a different name, symbol, address or creator—or clear your filters.",
                else: "New auctions and launched tokens will appear here as they become available."}
          </p>
          <.link
            :if={
              @market_options.q != "" or
                (@market_options.state != "all" or @market_options.chain != "all" or
                   @market_options.kind != "all" or @market_options.x or @market_options.ens or
                   @market_options.github)
            }
            patch={
              HomeMarket.path(@market_options, %{
                q: "",
                state: "all",
                chain: "all",
                kind: "all",
                x: false,
                ens: false,
                github: false
              })
            }
            class="rg-button rg-button--secondary"
          >Clear filters</.link>
          <Regent.Primitives.button
            :if={
              Autolaunch.Prelaunch.read_only?() && @market_options.q == "" &&
                @market_options.state == "all" && @market_options.chain == "all" &&
                @market_options.kind == "all" && !@market_options.x && !@market_options.ens &&
                !@market_options.github
            }
            disabled
            title={"Opens #{Autolaunch.Prelaunch.opens_at_label()}"}
          >Create an auction</Regent.Primitives.button>
          <.link
            :if={
              !Autolaunch.Prelaunch.read_only?() && @market_options.q == "" &&
                @market_options.state == "all" && @market_options.chain == "all" &&
                @market_options.kind == "all" && !@market_options.x && !@market_options.ens &&
                !@market_options.github
            }
            navigate="/create"
            class="rg-button rg-button--primary"
          >Create an auction</.link>
        </div>
        <div :if={@has_more && !@market_failed} class="home-load-more">
          <Regent.Primitives.button
            phx-click="load-more"
            disabled={@market_loading}
            variant="secondary"
          >{if @market_loading, do: "Loading…", else: "Load more"}</Regent.Primitives.button>
        </div>
        <p
          :if={!@market_loading && !@market_failed && @listed?}
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

  defp count_label(1, :token), do: "1 token"
  defp count_label(count, :token), do: "#{count} tokens"
  defp count_label(1, _kind), do: "1 auction"
  defp count_label(count, _kind), do: "#{count} auctions"
end
