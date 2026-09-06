defmodule AutolaunchWeb.HomeLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [
      connections_for: 2,
      creator_connections_for: 1,
      empty_market_copy: 2,
      grouped_connections: 1
    ]

  import AutolaunchWeb.Components.MarketCard
  import AutolaunchWeb.Components.TokenLinks, only: [regent_market_links: 1]

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(params, _uri, socket) do
    query = normalize_query(params["q"])
    market_view = market_view(params)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:market_view, market_view)
     |> assign(:listing_kind, listing_kind(market_view))
     |> assign_async([:listings, :creators], fn -> load_listings(query, market_view) end)}
  end

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
        <p :if={@listings.ok? && @listings.result == []} class="home-market__empty">
          {empty_copy(@search_query, @market_view)}
        </p>
        <div :if={@listings.ok? && @listings.result != []} class="home-coin-grid">
          <.autolaunch_market_card
            :for={record <- @listings.result}
            kind={@listing_kind}
            record={record}
            creator_connections={connections_for(record, grouped_connections(@creators))}
          />
        </div>
      </section>
    </main>
    """
  end

  defp load_listings(query, market_view) do
    records = read_list(fn -> list_records(query, market_view) end)
    {:ok, %{listings: records, creators: creator_connections_for(records)}}
  end

  defp list_records(query, :tokens), do: Autolaunch.list_graduated_launchpad_tokens(query)
  defp list_records(query, :active), do: Autolaunch.list_active_launchpad_auctions(query)
  defp list_records("", :new), do: Autolaunch.list_recent_auctions()
  defp list_records(query, :new), do: Autolaunch.list_explore_launchpad_auctions(query)

  defp listing_kind(:tokens), do: :token
  defp listing_kind(_view), do: :auction

  defp empty_copy(query, :tokens), do: empty_market_copy(query, "No tokens yet.")
  defp empty_copy(query, _view), do: empty_market_copy(query, "No auctions yet.")

  defp read_list(reader) do
    case reader.() do
      {:ok, records} -> records
      {:error, _reason} -> []
    end
  end

  defp market_view(%{"view" => "tokens"}), do: :tokens
  defp market_view(%{"view" => "new"}), do: :new
  defp market_view(%{"auctions" => "new"}), do: :new
  defp market_view(_params), do: :active

  defp normalize_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.graphemes()
    |> Enum.take(80)
    |> Enum.join()
  end

  defp normalize_query(_query), do: ""

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
