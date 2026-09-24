defmodule AutolaunchWeb.HomeLive do
  @moduledoc false
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [
      connections_for: 2,
      creator_connections_for: 1,
      current_human_id: 1,
      explore_table: 1,
      robinhood?: 1
    ]

  import AutolaunchWeb.Components.MarketCard,
    only: [auction_list: 1, explore_card: 1, assign_figure_rates: 1, figure_rate: 2]

  import AutolaunchWeb.Components.Opening, only: [welcome: 1]
  import AutolaunchWeb.Components.SwapModal
  import AutolaunchWeb.Components.AuctionStats
  alias Autolaunch.HomeMarket
  alias AutolaunchWeb.{LabMarket, LiveListings}

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       market_options: nil,
       trade: nil,
       records: [],
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

  def handle_event("filter", params, socket) do
    changes =
      Map.take(params, ~w(sort state chain kind x ens github))
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

    {:noreply, push_patch(socket, to: HomeMarket.path(socket.assigns.market_options, changes))}
  end

  def handle_event(
        "load-more",
        _params,
        %{assigns: %{market_loading: false, has_more: true}} = socket
      ),
      do: {:noreply, load_market(socket, true)}

  def handle_event("load-more", _params, socket), do: {:noreply, socket}

  def handle_event("open_trade", %{"id" => id} = params, socket) do
    trade =
      case !socket.assigns.market_loading && Enum.find(socket.assigns.records, &(&1.id == id)) do
        %{} = record -> %{record: record, amount: params["amount"]}
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
       creators: creators,
       next_cursor: page.next_cursor,
       has_more: page.has_more,
       market_loading: false,
       market_failed: false
     )}
  end

  def handle_async(:home_market, _failure, socket),
    do: {:noreply, assign(socket, market_loading: false, market_failed: true)}

  # A reread answers only for the listing it was asked about; a filter, search
  # or load started meanwhile brings its own records.
  def handle_async(:home_reread, {:ok, {options, {:ok, page}}}, socket) do
    if options == socket.assigns.market_options and not socket.assigns.market_loading do
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

  defp load_market(socket, append?) do
    options = socket.assigns.market_options
    cursor = if append?, do: socket.assigns.next_cursor

    socket =
      if append?,
        do: socket,
        else: assign(socket, records: [], creators: %{}, has_more: false, next_cursor: nil)

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

      {options, result}
    end)
  end

  defp network_label("base"), do: "Base"
  defp network_label("robinhood"), do: "Robinhood"
  defp network_label(_), do: "Base + Robinhood"

  def render(assigns) do
    assigns =
      assign(assigns,
        kind: if(assigns.market_options.view == "tokens", do: :token, else: :auction),
        listed?: assigns.records != []
      )

    ~H"""
    <main class="home-page home-explore-page" id="home-explore">
      <.welcome :if={Autolaunch.Prelaunch.read_only?()} />
      <.auction_stats revstake={@revstake_stats} memestake={@memestake_stats} />
      <header class="home-heading">
        <div class="home-heading__discovery">
          <h1 id="home-explore-title">Explore</h1>
          <nav class="home-kind-toggle" aria-label="Explore auctions or graduated tokens">
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
        </div>
        <span class="home-network" title="The network these listings belong to">
          <span aria-hidden="true" class="home-network__dot"></span>
          {if @local_lab,
            do: "#{Autolaunch.ChainMode.label()} · test assets",
            else: network_label(@market_options.chain)}
        </span>
      </header>

      <div class="home-toolbar">
        <div class="home-tools">
          <form id="home-filter-form" phx-change="filter" phx-submit="filter" class="home-filter-form">
            <label class="home-sort">
              <span class="visually-hidden">Sort coins</span>
              <select name="sort" aria-label="Sort coins">
                <option value="newest" selected={@market_options.sort == "newest"}>
                  Recently launched
                </option>
                <option
                  :if={@market_options.view == "auctions"}
                  value="ending"
                  selected={@market_options.sort == "ending"}
                >
                  Closing soon · live auctions
                </option>
                <option
                  :if={@market_options.view == "auctions"}
                  value="volume"
                  selected={@market_options.sort == "volume"}
                >
                  Highest bid volume · USD estimate
                </option>
                <option value="oldest" selected={@market_options.sort == "oldest"}>
                  Oldest first
                </option>
              </select>
            </label>
            <details
              id="home-filters"
              class="home-filter"
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
                <label :if={@market_options.view != "tokens"} for="home-state">Auction state</label>
                <select :if={@market_options.view != "tokens"} name="state" id="home-state">
                  <option value="all" selected={@market_options.state == "all"}>
                    All auctions
                  </option>
                  <option value="created" selected={@market_options.state == "created"}>
                    Opening soon
                  </option>
                  <option value="active" selected={@market_options.state == "active"}>Live</option>
                  <option value="ended" selected={@market_options.state == "ended"}>
                    Waiting to finish
                  </option>
                  <option
                    value="failed"
                    selected={@market_options.state == "failed"}
                  >
                    Failed
                  </option>
                  <option value="graduated" selected={@market_options.state == "graduated"}>
                    Graduated
                  </option>
                </select>
                <label for="home-chain">Network</label>
                <select name="chain" id="home-chain">
                  <option
                    :for={
                      {value, label} <- [
                        {"all", "All networks"},
                        {"base", "Base"},
                        {"robinhood", "Robinhood"}
                      ]
                    }
                    value={value}
                    selected={@market_options.chain == value}
                  >
                    {label}
                  </option>
                </select>
                <label for="home-launch-kind">Auction type</label>
                <select name="kind" id="home-launch-kind">
                  <option
                    :for={
                      {value, label} <- [
                        {"all", "All types"},
                        {"revstake", "Revstake"},
                        {"memestake", "Memestake"}
                      ]
                    }
                    value={value}
                    selected={@market_options.kind == value}
                  >
                    {label}
                  </option>
                </select>
                <fieldset class="home-social-filters">
                  <legend>Creator connections</legend>
                  <label :for={{key, label} <- [x: "X", ens: "ENS", github: "GitHub"]}>
                    <input type="hidden" name={key} value="false" />
                    <input
                      type="checkbox"
                      name={key}
                      value="true"
                      checked={Map.fetch!(@market_options, key)}
                    />
                    {label}
                  </label>
                  <small>Match every selected connection.</small>
                </fieldset>
                <.link patch={
                  HomeMarket.path(@market_options, %{
                    state: "all",
                    chain: "all",
                    kind: "all",
                    x: false,
                    ens: false,
                    github: false
                  })
                }>Reset filters</.link>
              </div>
            </details>
          </form>
          <nav class="home-display" aria-label="Display mode">
            <.link
              :for={{value, label} <- [{"grid", "Grid"}, {"table", "Table"}]}
              patch={HomeMarket.path(@market_options, %{display: value})}
              aria-current={if @market_options.display == value, do: "page"}
            >{label}</.link>
          </nav>
        </div>
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
            kind={@kind}
            record={record}
            creator_connections={connections_for(record, @creators)}
            trade_event="open_trade"
            rate={if @kind == :auction, do: figure_rate(@rates, record)}
          />
        </div>
        <.auction_list
          :if={@listed? && @market_options.display == "table" && @kind == :auction}
          records={@records}
          creators={@creators}
          rates={@rates}
        />
        <.explore_table
          :if={@listed? && @market_options.display == "table" && @kind == :token}
          kind={@kind}
          records={@records}
          creators={@creators}
          trade_event="open_trade"
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
                else: "New auctions and graduated tokens will appear here as they become available."}
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
          Showing {length(@records)} {if @kind == :token,
            do: "tokens",
            else: "auctions"}{if !@has_more,
            do: " · All results loaded"}
        </p>
      </section>
      <.swap_modal
        :if={@trade && @kind == :token}
        id={"home-trade-#{@trade.record.id}"}
        token={@trade.record}
        amount={@trade.amount}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.robinhood_bid_modal
        :if={match?(%{record: %Autolaunch.Auction{}}, @trade) && robinhood?(@trade.record)}
        id={"home-robinhood-bid-#{@trade.record.id}"}
        auction={@trade.record}
        amount={@trade.amount}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.bid_modal
        :if={match?(%{record: %Autolaunch.Auction{}}, @trade) && !robinhood?(@trade.record)}
        id={"home-bid-#{@trade.record.id}"}
        auction={@trade.record}
        amount={@trade.amount}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
    </main>
    """
  end
end
