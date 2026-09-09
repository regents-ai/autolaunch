defmodule AutolaunchWeb.HomeLive do
  @moduledoc false
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1]

  import AutolaunchWeb.Components.MarketCard, only: [explore_card: 1, explore_row: 1]
  alias Autolaunch.HomeMarket

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       market_options: nil,
       records: [],
       creators: %{},
       market_loading: true,
       market_failed: false,
       market_append: false,
       next_cursor: nil,
       has_more: false,
       local_lab: Autolaunch.Lab.enabled?()
     )}
  end

  def handle_params(params, _uri, socket) do
    options = HomeMarket.options(params)
    previous = socket.assigns.market_options
    socket = assign(socket, market_options: options, search_query: options.q)

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

  defp load_market(socket, append?) do
    options = socket.assigns.market_options
    cursor = if append?, do: socket.assigns.next_cursor

    socket =
      if append?,
        do: socket,
        else: assign(socket, records: [], creators: %{}, has_more: false, next_cursor: nil)

    socket
    |> assign(market_loading: true, market_failed: false, market_append: append?)
    |> start_async(:home_market, fn ->
      with {:ok, page} <- HomeMarket.read(options, cursor) do
        {:ok, Map.put(page, :creators, creator_connections_for(page.records))}
      end
    end)
  end

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :kind,
        if(assigns.market_options.view == "tokens", do: :token, else: :auction)
      )

    ~H"""
    <main class="home-page home-explore-page" id="home-explore">
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
                    All in this category
                  </option>
                  <option value="created" selected={@market_options.state == "created"}>
                    Created
                  </option>
                  <option value="active" selected={@market_options.state == "active"}>Active</option>
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
          :if={@market_loading && @records == []}
          class="home-coin-grid home-skeletons"
          aria-hidden="true"
        >
          <div :for={index <- 1..12} id={"home-skeleton-#{index}"} class="home-skeleton">
            <div class="home-skeleton__image"></div><div class="home-skeleton__line"></div><div class="home-skeleton__line home-skeleton__line--short">
            </div>
          </div>
        </div>
        <p :if={@market_loading} class="visually-hidden" role="status">Loading coins</p>

        <div :if={@records != [] && @market_options.display == "grid"} class="home-coin-grid">
          <.explore_card
            :for={record <- @records}
            kind={@kind}
            record={record}
            creator_connections={connections_for(record, @creators)}
          />
        </div>
        <div :if={@records != [] && @market_options.display == "table"} class="home-table-scroll">
          <table class="home-table">
            <caption class="visually-hidden">
              {if @kind == :token, do: "Graduated tokens", else: "Auctions"}
            </caption>
            <thead>
              <tr>
                <th scope="col">Coin</th><th scope="col">
                  {if @kind == :token, do: "Price", else: "Clearing price"}
                </th><th scope="col">Creator</th><th scope="col">Age</th><th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              <.explore_row
                :for={record <- @records}
                kind={@kind}
                record={record}
                creator_connections={connections_for(record, @creators)}
              />
            </tbody>
          </table>
        </div>

        <Regent.Primitives.notice :if={@market_failed} tone="error" class="home-market__error">
          <p>
            {if @market_append,
              do: "More coins could not be loaded. Your current results are still here.",
              else: "Listings are unavailable right now."}
          </p>
          <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
        </Regent.Primitives.notice>
        <div
          :if={!@market_loading && !@market_failed && @records == []}
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
            title="Available after contract deployment"
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
          :if={!@market_loading && !@market_failed && @records != []}
          class="home-result-count"
          role="status"
        >
          Showing {length(@records)} {if @kind == :token, do: "tokens", else: "auctions"}{if !@has_more,
            do: " · All results loaded"}
        </p>
      </section>
    </main>
    """
  end
end
