defmodule AutolaunchWeb.HomeLive do
  @moduledoc false
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [
      connections_for: 2,
      creator_connections_for: 1,
      current_human_id: 1,
      explore_table: 1,
      opened_robinhood_bid: 3
    ]

  import AutolaunchWeb.Components.MarketCard, only: [explore_card: 1]
  import AutolaunchWeb.Components.Opening, only: [welcome: 1]
  import AutolaunchWeb.Components.SwapModal
  import AutolaunchWeb.Components.AuctionStats
  alias Autolaunch.HomeMarket
  alias AutolaunchWeb.LiveListings

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       market_options: nil,
       trade: nil,
       records: [],
       creators: %{},
       robinhood: [],
       robinhood_creators: %{},
       robinhood_failed: false,
       market_loading: true,
       market_failed: false,
       market_append: false,
       next_cursor: nil,
       has_more: false,
       local_lab: Autolaunch.Lab.test_chain?()
     )
     |> LiveListings.subscribe()
     |> assign_auction_stats()}
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
    changes = %{sort: Map.get(params, "sort", "newest"), state: Map.get(params, "state", "all")}
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

  def handle_event("open_robinhood_bid", %{"id" => address} = params, socket),
    do:
      {:noreply,
       assign(socket, :trade, opened_robinhood_bid(socket.assigns.robinhood, address, params))}

  def handle_event("open_robinhood_bid", _params, socket), do: {:noreply, socket}

  def handle_event("close_trade", %{"id" => id}, socket) do
    case socket.assigns.trade do
      %{record: %{id: ^id}} -> {:noreply, assign(socket, :trade, nil)}
      %{record: %{auction: ^id}} -> {:noreply, assign(socket, :trade, nil)}
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

  def handle_async(:home_robinhood, {:ok, {:ok, auctions, creators}}, socket),
    do:
      {:noreply,
       assign(socket, robinhood: auctions, robinhood_creators: creators, robinhood_failed: false)}

  def handle_async(:home_robinhood, _failure, socket),
    do: {:noreply, assign(socket, robinhood: [], robinhood_creators: %{}, robinhood_failed: true)}

  def handle_info({:autolaunch_listings_changed, _auction_id}, socket),
    do: {:noreply, LiveListings.schedule(socket)}

  def handle_info(:reread_listings, socket),
    do: {:noreply, socket |> LiveListings.taken() |> reread_market() |> assign_auction_stats()}

  # Robinhood entries carry no opening time to page by, so they lead the first page.
  defp load_robinhood(socket, true), do: socket

  defp load_robinhood(socket, false) do
    options = socket.assigns.market_options

    socket
    |> assign(robinhood: [], robinhood_creators: %{}, robinhood_failed: false)
    |> start_async(:home_robinhood, fn ->
      with {:ok, auctions} <- HomeMarket.robinhood(options),
           do: {:ok, auctions, creator_connections_for(auctions)}
    end)
  end

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
    |> load_robinhood(append?)
  end

  # The records loaded so far, read again in place: the filters, the pages
  # loaded with "Load more" and an open bid form all stay. Robinhood entries
  # come from their chain, not the saved records, so they are not read again.
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

  def render(assigns) do
    assigns =
      assign(assigns,
        kind: if(assigns.market_options.view == "tokens", do: :token, else: :auction),
        listed?: assigns.records != [] or assigns.robinhood != []
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
          {if @local_lab, do: "#{Autolaunch.ChainMode.label()} · test assets", else: "Base"}
        </span>
      </header>

      <div class="home-toolbar">
        <div class="home-tools">
          <form id="home-filter-form" phx-change="filter" phx-submit="filter" class="home-filter-form">
            <label class="home-sort">
              <span class="visually-hidden">Sort coins</span>
              <select name="sort" aria-label="Sort coins">
                <option value="newest" selected={@market_options.sort == "newest"}>
                  Newest first
                </option>
                <option value="oldest" selected={@market_options.sort == "oldest"}>
                  Oldest first
                </option>
              </select>
            </label>
            <details :if={@market_options.view != "tokens"} class="home-filter">
              <summary>
                Filter<span
                  :if={@market_options.state != "all"}
                  class="home-filter__active"
                  aria-label="Filter active"
                ></span>
              </summary>
              <div class="home-filter__panel">
                <label for="home-state">Auction state</label>
                <select name="state" id="home-state">
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
                </select>
                <.link patch={HomeMarket.path(@market_options, %{state: "all"})}>Reset filter</.link>
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

        <Regent.Primitives.notice :if={@robinhood_failed} tone="error" class="home-market__error">
          <p>
            {if @kind == :token,
              do: "Robinhood tokens are unavailable right now.",
              else: "Robinhood auctions are unavailable right now."}
          </p>
        </Regent.Primitives.notice>
        <div :if={@listed? && @market_options.display == "grid"} class="home-coin-grid">
          <.explore_card
            :for={entry <- @robinhood}
            kind={if @kind == :token, do: :robinhood_token, else: :robinhood_auction}
            record={entry}
            creator_connections={connections_for(entry, @robinhood_creators)}
            trade_event="open_robinhood_bid"
          />
          <.explore_card
            :for={record <- @records}
            kind={@kind}
            record={record}
            creator_connections={connections_for(record, @creators)}
            trade_event="open_trade"
          />
        </div>
        <.explore_table
          :if={@listed? && @market_options.display == "table"}
          kind={@kind}
          records={@records}
          creators={Map.merge(@creators, @robinhood_creators)}
          trade_event="open_trade"
          robinhood={@robinhood}
          robinhood_trade_event="open_robinhood_bid"
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
            {if @market_options.q != "" or @market_options.state != "all",
              do: "No matching coins",
              else: "No coins in this category yet"}
          </h2>
          <p>
            {if @market_options.q != "" or @market_options.state != "all",
              do: "Try a different name, symbol, address or creator—or clear your filters.",
              else: "New auctions and graduated tokens will appear here as they become available."}
          </p>
          <.link
            :if={@market_options.q != "" or @market_options.state != "all"}
            patch={HomeMarket.path(@market_options, %{q: "", state: "all"})}
            class="rg-button rg-button--secondary"
          >Clear filters</.link>
          <Regent.Primitives.button
            :if={
              Autolaunch.Prelaunch.read_only?() && @market_options.q == "" &&
                @market_options.state == "all"
            }
            disabled
            title={"Opens #{Autolaunch.Prelaunch.opens_at_label()}"}
          >Create an auction</Regent.Primitives.button>
          <.link
            :if={
              !Autolaunch.Prelaunch.read_only?() && @market_options.q == "" &&
                @market_options.state == "all"
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
          Showing {length(@records) + length(@robinhood)} {if @kind == :token,
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
        :if={match?(%{record: %{launch_id: _}}, @trade)}
        id={"home-robinhood-bid-#{@trade.record.auction}"}
        auction={@trade.record}
        amount={@trade.amount}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.bid_modal
        :if={match?(%{record: %Autolaunch.Auction{}}, @trade)}
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
