defmodule AutolaunchWeb.TokensLive do
  @moduledoc """
  The tokens list: every launched token as a table row with its price, market
  cap and when it launched, filtered by chain, search and the creator's
  verified connections.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [creator_connections_for: 1]

  import AutolaunchWeb.Components.MarketCard,
    only: [token_list: 1, assign_figure_rates: 1, list_tools: 1]

  alias Autolaunch.HomeMarket
  alias AutolaunchWeb.{LabMarket, LiveListings}

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
     |> assign_figure_rates()}
  end

  def handle_params(params, _uri, socket) do
    options = params |> Map.put("view", "tokens") |> HomeMarket.options()

    if options == socket.assigns.options,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(:options, options) |> load(false)}
  end

  def handle_event("search", params, socket),
    do: {:noreply, patch(socket, %{q: Map.get(params, "q", "")})}

  def handle_event("filter", params, socket) do
    changes =
      params
      |> Map.take(~w(chain x ens github))
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

    {:noreply, patch(socket, changes)}
  end

  def handle_event("load-more", _params, %{assigns: %{loading: false, has_more: true}} = socket),
    do: {:noreply, load(socket, true)}

  def handle_event("load-more", _params, socket), do: {:noreply, socket}

  def handle_event("retry", _params, socket), do: {:noreply, load(socket, socket.assigns.append)}

  def handle_async(:tokens, {:ok, {:ok, page}}, socket) do
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

  def handle_async(:tokens, _failure, socket),
    do: {:noreply, assign(socket, loading: false, failed: true)}

  # A reread answers only for the list it was asked about; a filter, search or
  # load started meanwhile brings its own records.
  def handle_async(:tokens_reread, {:ok, {options, {:ok, page}}}, socket) do
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
  def handle_async(:tokens_reread, _failure, socket), do: {:noreply, socket}

  # The Robinhood notice follows whether its feed could read Robinhood.
  def handle_info({:autolaunch_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def handle_info({:robinhood_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def handle_info({:autolaunch_listings_changed, _auction_id}, socket),
    do: {:noreply, LiveListings.schedule(socket)}

  def handle_info(:reread_listings, socket),
    do: {:noreply, socket |> LiveListings.taken() |> reread()}

  defp patch(socket, changes),
    do: push_patch(socket, to: list_path(socket.assigns.options, changes))

  defp list_path(options, changes), do: HomeMarket.path(options, changes, "/tokens")

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
    |> start_async(:tokens, fn -> with_creators(HomeMarket.read(options, cursor)) end)
  end

  # The records loaded so far, read again in place, so every loaded page and
  # the filters stay.
  defp reread(socket) do
    options = socket.assigns.options
    count = length(socket.assigns.records)

    start_async(socket, :tokens_reread, fn ->
      {options, with_creators(HomeMarket.reread(options, count))}
    end)
  end

  defp with_creators({:ok, page}),
    do: {:ok, Map.put(page, :creators, creator_connections_for(page.records))}

  defp with_creators(error), do: error

  defp filtered?(options),
    do: options.q != "" or options.chain != "all" or options.x or options.ens or options.github

  def render(assigns) do
    ~H"""
    <main class="autolaunch-page market-list-page" id="tokens-list">
      <header class="market-list__header">
        <h1 id="tokens-list-title">Tokens</h1>
      </header>

      <.list_tools kind="tokens" options={@options} />

      <section
        id="tokens-market"
        class="market-list"
        aria-labelledby="tokens-list-title"
        aria-busy={to_string(@loading)}
      >
        <Regent.Primitives.notice :if={@market.robinhood_stale?} role="status">
          <p>Robinhood could not be read just now, so its tokens show what was last read.</p>
        </Regent.Primitives.notice>
        <p :if={@loading} class="visually-hidden" role="status">Loading tokens</p>

        <.token_list
          :if={@records != [] or @loading}
          records={@records}
          creators={@creators}
          rates={@rates}
          loading={@loading}
        />

        <Regent.Primitives.notice :if={@failed} tone="error">
          <p>
            {if @append,
              do: "More tokens could not be loaded. The ones shown are still here.",
              else: "Tokens are unavailable right now."}
          </p>
          <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
        </Regent.Primitives.notice>

        <div :if={!@loading && !@failed && @records == []} class="market-list__empty" role="status">
          <h2>{if filtered?(@options), do: "No matching tokens", else: "No tokens yet"}</h2>
          <p>
            {if filtered?(@options),
              do: "Try a different search, or clear your filters.",
              else: "Tokens appear here once their auction launches."}
          </p>
          <.link
            :if={filtered?(@options)}
            patch={list_path(@options, %{q: "", chain: "all", x: false, ens: false, github: false})}
            class="rg-button rg-button--secondary"
          >Clear filters</.link>
          <.link
            :if={!filtered?(@options)}
            navigate="/auctions"
            class="rg-button rg-button--secondary"
          >
            Browse auctions
          </.link>
        </div>

        <div :if={@has_more && !@failed} class="market-list__more">
          <Regent.Primitives.button phx-click="load-more" disabled={@loading} variant="secondary">
            {if @loading, do: "Loading…", else: "Load more"}
          </Regent.Primitives.button>
        </div>
      </section>
    </main>
    """
  end
end
