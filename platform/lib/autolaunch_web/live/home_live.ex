defmodule AutolaunchWeb.HomeLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1, empty_market_copy: 2]

  import AutolaunchWeb.Components.MarketCard
  import AutolaunchWeb.Components.TokenLinks, only: [regent_market_links: 1]
  import AutolaunchWeb.Components.TopBar, only: [normalize_query: 1]

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:search_query, normalize_query(params["q"]))
     |> assign(:market_view, market_view(params))
     |> load_market()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_market(socket)}

  def render(assigns) do
    ~H"""
    <main class="home-page launchpad-home">
      <header class="home-explore">
        <div
          id="autolaunch-crown"
          class="home-crown"
          phx-hook="Optics"
          phx-update="ignore"
          data-optics-kind="crown"
          data-optics-source={~p"/assets/js/crown_island.js"}
          data-crown-variant="4"
          aria-hidden="true"
        >
          <canvas
            id="autolaunch-crown-canvas"
            class="home-crown__canvas"
            data-optics-canvas
            data-crown-variant="4"
          ></canvas>
        </div>
        <p class="home-explore__kicker">Autolaunch</p>
        <h1 id="home-explore-title">Explore coins</h1>
        <nav class="home-filters" aria-label="Market filters">
          <.link
            patch={home_path(@search_query, :active)}
            class="home-chip"
            aria-current={if @market_view == :active, do: "true"}
          >
            Active
          </.link>
          <.link
            patch={home_path(@search_query, :new)}
            class="home-chip"
            aria-current={if @market_view == :new, do: "true"}
          >
            New
          </.link>
          <.link
            patch={home_path(@search_query, :tokens)}
            class="home-chip"
            aria-current={if @market_view == :tokens, do: "true"}
          >
            Tokens
          </.link>
          <.link navigate={~p"/create"} class="home-chip home-chip--create">Create</.link>
        </nav>
        <.regent_market_links />
      </header>

      <section id="home-market" class="home-market" aria-labelledby="home-explore-title">
        <p :if={@market.loading && !@market.ok?} class="home-market__empty" role="status">
          Loading…
        </p>
        <Regent.Primitives.notice :if={@market.failed} tone="error" class="home-market__error">
          <p>Listings are unavailable right now.</p>
          <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
        </Regent.Primitives.notice>
        <p :if={listed?(@market) && @market.result.records == []} class="home-market__empty">
          {empty_copy(@search_query, @market_view)}
        </p>
        <div :if={listed?(@market) && @market.result.records != []} class="home-coin-grid">
          <.autolaunch_market_card
            :for={record <- @market.result.records}
            kind={@market.result.kind}
            record={record}
            creator_connections={connections_for(record, @market.result.creators)}
          />
        </div>
      </section>
    </main>
    """
  end

  # A failed read never shows the rows of the filter it replaced.
  defp listed?(market), do: market.ok? and is_nil(market.failed)

  # The kind travels with the rows it describes, so a filter change never
  # renders the previous filter's rows as the new kind while the read is out.
  defp load_market(socket) do
    query = socket.assigns.search_query
    market_view = socket.assigns.market_view

    assign_async(socket, :market, fn -> load_listings(query, market_view) end)
  end

  defp load_listings(query, market_view) do
    case list_records(query, market_view) do
      {:ok, records} ->
        {:ok,
         %{
           market: %{
             kind: listing_kind(market_view),
             records: records,
             creators: creator_connections_for(records)
           }
         }}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp list_records(query, :tokens), do: Autolaunch.list_graduated_launchpad_tokens(query)
  defp list_records(query, :active), do: Autolaunch.list_active_launchpad_auctions(query)
  defp list_records("", :new), do: Autolaunch.list_recent_auctions()
  defp list_records(query, :new), do: Autolaunch.list_explore_launchpad_auctions(query)

  defp listing_kind(:tokens), do: :token
  defp listing_kind(_view), do: :auction

  defp empty_copy(query, :tokens), do: empty_market_copy(query, "No tokens yet.")
  defp empty_copy(query, _view), do: empty_market_copy(query, "No auctions yet.")

  defp market_view(%{"view" => "tokens"}), do: :tokens
  defp market_view(%{"view" => "new"}), do: :new
  defp market_view(%{"auctions" => "new"}), do: :new
  defp market_view(_params), do: :active

  defp home_path(query, view) do
    params =
      []
      |> maybe_put("q", query)
      |> maybe_put("view", view_param(view))

    case params do
      [] -> "/"
      params -> "/?" <> URI.encode_query(params)
    end
  end

  defp view_param(:new), do: "new"
  defp view_param(:tokens), do: "tokens"
  defp view_param(:active), do: nil

  defp maybe_put(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put(params, key, value), do: params ++ [{key, value}]
end
