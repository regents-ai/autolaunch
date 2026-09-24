defmodule AutolaunchWeb.AuctionsLive do
  @moduledoc """
  The auctions list: every auction as a table row with its FDV at the floor
  price, bid volume, launch threshold and status, filtered by chain, status,
  search and the creator's verified connections.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1]

  import AutolaunchWeb.Components.MarketCard,
    only: [auction_list_row: 1, assign_figure_rates: 1, figure_rate: 2]

  import AutolaunchWeb.Components.AuctionStats
  alias Autolaunch.HomeMarket
  alias AutolaunchWeb.{LabMarket, LiveListings}

  @verifications [x: "X", ens: "ENS", github: "GitHub"]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       options: nil,
       records: [],
       creators: %{},
       market: LabMarket.subscribe(socket),
       loading: true,
       failed: false,
       append: false,
       next_cursor: nil,
       has_more: false
     )
     |> LiveListings.subscribe()
     |> assign_auction_stats()
     |> assign_figure_rates()}
  end

  def handle_params(params, _uri, socket) do
    options = params |> Map.put("view", "auctions") |> HomeMarket.options()

    if options == socket.assigns.options,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(:options, options) |> load(false)}
  end

  def handle_event("search", params, socket),
    do: {:noreply, patch(socket, %{q: Map.get(params, "q", "")})}

  def handle_event("filter", params, socket) do
    changes =
      params
      |> Map.take(~w(chain state x ens github))
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

    {:noreply, patch(socket, changes)}
  end

  def handle_event("load-more", _params, %{assigns: %{loading: false, has_more: true}} = socket),
    do: {:noreply, load(socket, true)}

  def handle_event("load-more", _params, socket), do: {:noreply, socket}

  def handle_event("retry", _params, socket), do: {:noreply, load(socket, socket.assigns.append)}

  def handle_async(:auctions, {:ok, {:ok, page}}, socket) do
    {records, creators} =
      if socket.assigns.append,
        do:
          {Enum.uniq_by(socket.assigns.records ++ page.records, & &1.id),
           Map.merge(socket.assigns.creators, page.creators)},
        else: {page.records, page.creators}

    {:noreply,
     assign(socket,
       records: records,
       creators: creators,
       next_cursor: page.next_cursor,
       has_more: page.has_more,
       loading: false,
       failed: false
     )}
  end

  def handle_async(:auctions, _failure, socket),
    do: {:noreply, assign(socket, loading: false, failed: true)}

  # A reread answers only for the list it was asked about; a filter, search or
  # load started meanwhile brings its own records.
  def handle_async(:auctions_reread, {:ok, {options, {:ok, page}}}, socket) do
    if options == socket.assigns.options and not socket.assigns.loading do
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

  # A failed reread leaves the list the reader already has.
  def handle_async(:auctions_reread, _failure, socket), do: {:noreply, socket}

  # The Robinhood notice follows whether its feed could read Robinhood.
  def handle_info({:autolaunch_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def handle_info({:robinhood_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def handle_info({:autolaunch_listings_changed, _auction_id}, socket),
    do: {:noreply, LiveListings.schedule(socket)}

  def handle_info(:reread_listings, socket),
    do: {:noreply, socket |> LiveListings.taken() |> reread() |> assign_auction_stats()}

  defp patch(socket, changes),
    do: push_patch(socket, to: list_path(socket.assigns.options, changes))

  defp list_path(options, changes), do: HomeMarket.path(options, changes, "/auctions")

  defp load(socket, append?) do
    options = socket.assigns.options
    cursor = if append?, do: socket.assigns.next_cursor

    socket
    |> then(
      &if(append?,
        do: &1,
        else: assign(&1, records: [], creators: %{}, has_more: false, next_cursor: nil)
      )
    )
    |> assign(loading: true, failed: false, append: append?)
    |> start_async(:auctions, fn -> with_creators(HomeMarket.read(options, cursor)) end)
  end

  # The records loaded so far, read again in place, so every loaded page and
  # the filters stay.
  defp reread(socket) do
    options = socket.assigns.options
    count = length(socket.assigns.records)

    start_async(socket, :auctions_reread, fn ->
      {options, with_creators(HomeMarket.reread(options, count))}
    end)
  end

  defp with_creators({:ok, page}),
    do: {:ok, Map.put(page, :creators, creator_connections_for(page.records))}

  defp with_creators(error), do: error

  defp pill(options) do
    cond do
      options.state == "graduated" -> :launched
      options.state == "active" and options.sort == "newest" -> :new
      options.state == "all" and not (options.x or options.ens or options.github) -> :all
      true -> nil
    end
  end

  defp verified?(options), do: options.x or options.ens or options.github

  defp filtered?(options),
    do: options.q != "" or options.state != "all" or options.chain != "all" or verified?(options)

  @all %{state: "all", sort: "newest", x: false, ens: false, github: false}

  def render(assigns) do
    assigns =
      assign(assigns,
        pill: pill(assigns.options),
        verifications: @verifications,
        all: @all
      )

    ~H"""
    <main class="autolaunch-page auction-list-page" id="auctions-list">
      <.auction_stats revstake={@revstake_stats} memestake={@memestake_stats} />
      <header class="auction-list__header">
        <h1 id="auctions-list-title">Auctions</h1>
        <Regent.Primitives.button
          :if={Autolaunch.Prelaunch.read_only?()}
          disabled
          title={"Opens #{Autolaunch.Prelaunch.opens_at_label()}"}
        >Launch auction</Regent.Primitives.button>
        <.link
          :if={!Autolaunch.Prelaunch.read_only?()}
          navigate="/create"
          class="rg-button rg-button--primary"
        ><span class="rg-button__label">Launch auction</span></.link>
      </header>

      <div class="auction-list__tools">
        <form
          id="auctions-filter-form"
          class="auction-list__filters"
          phx-change="filter"
          phx-submit="filter"
        >
          <label>
            <span class="visually-hidden">Chain</span>
            <select name="chain" aria-label="Chain">
              <option
                :for={
                  {value, label} <- [
                    {"all", "All chains"},
                    {"base", "Base"},
                    {"robinhood", "Robinhood"}
                  ]
                }
                value={value}
                selected={@options.chain == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label>
            <span class="visually-hidden">Status</span>
            <select name="state" aria-label="Status">
              <option
                :for={
                  {value, label} <- [
                    {"all", "Any status"},
                    {"created", "Opening soon"},
                    {"active", "Live"},
                    {"ended", "Waiting to finish"},
                    {"graduated", "Launched"},
                    {"failed", "Failed"}
                  ]
                }
                value={value}
                selected={@options.state == value}
              >
                {label}
              </option>
            </select>
          </label>
          <details
            id="auctions-verified"
            class={["auction-list__verified-menu", verified?(@options) && "is-active"]}
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
          >
            <summary>Verified</summary>
            <fieldset>
              <legend>Creator has verified</legend>
              <label :for={{key, label} <- @verifications}>
                <input type="hidden" name={key} value="false" />
                <input type="checkbox" name={key} value="true" checked={Map.fetch!(@options, key)} />
                {label}
              </label>
              <small>Shows auctions whose creator has every one you tick.</small>
            </fieldset>
          </details>
        </form>
        <form
          id="auctions-search"
          class="auction-list__search"
          phx-submit="search"
          phx-change="search"
        >
          <label>
            <span class="visually-hidden">Search auctions</span>
            <input
              type="search"
              name="q"
              value={@options.q}
              placeholder="Search name, ticker or address"
              phx-debounce="300"
              autocomplete="off"
            />
          </label>
        </form>
      </div>

      <nav class="auction-list__pills" aria-label="Quick filters">
        <.link patch={list_path(@options, @all)} aria-current={if @pill == :all, do: "page"}>All</.link>
        <.link
          patch={list_path(@options, %{state: "active", sort: "newest"})}
          aria-current={if @pill == :new, do: "page"}
        >New</.link>
        <.link
          patch={list_path(@options, %{state: "graduated"})}
          aria-current={if @pill == :launched, do: "page"}
        >Launched</.link>
      </nav>

      <section
        id="auctions-market"
        class="auction-list"
        aria-labelledby="auctions-list-title"
        aria-busy={to_string(@loading)}
      >
        <Regent.Primitives.notice :if={@market.robinhood_stale?} role="status">
          <p>Robinhood could not be read just now, so its auctions show what was last read.</p>
        </Regent.Primitives.notice>
        <p :if={@loading} class="visually-hidden" role="status">Loading auctions</p>

        <div :if={@records != [] or @loading} class="auction-list__scroll">
          <table class="auction-list__table">
            <caption class="visually-hidden">Auctions</caption>
            <thead>
              <tr>
                <th scope="col">Token</th>
                <th scope="col">FDV at floor</th>
                <th scope="col">Bid volume</th>
                <th scope="col">Launch threshold</th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              <.auction_list_row
                :for={record <- @records}
                auction={record}
                creator_connections={connections_for(record, @creators)}
                rate={figure_rate(@rates, record)}
              />
              <tr
                :for={index <- 1..6}
                :if={@loading && @records == []}
                id={"auctions-loading-#{index}"}
                class="auction-list__skeleton"
                aria-hidden="true"
              >
                <td colspan="5"></td>
              </tr>
            </tbody>
          </table>
        </div>

        <Regent.Primitives.notice :if={@failed} tone="error">
          <p>
            {if @append,
              do: "More auctions could not be loaded. The ones shown are still here.",
              else: "Auctions are unavailable right now."}
          </p>
          <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
        </Regent.Primitives.notice>

        <div :if={!@loading && !@failed && @records == []} class="auction-list__empty" role="status">
          <h2>{if filtered?(@options), do: "No matching auctions", else: "No auctions yet"}</h2>
          <p :if={filtered?(@options)}>Try a different search, or clear your filters.</p>
          <.link
            :if={filtered?(@options)}
            patch={list_path(@options, Map.merge(@all, %{q: "", chain: "all"}))}
            class="rg-button rg-button--secondary"
          >Clear filters</.link>
        </div>

        <div :if={@has_more && !@failed} class="auction-list__more">
          <Regent.Primitives.button phx-click="load-more" disabled={@loading} variant="secondary">
            {if @loading, do: "Loading…", else: "Load more"}
          </Regent.Primitives.button>
        </div>
      </section>
    </main>
    """
  end
end
