defmodule AutolaunchWeb.HomeLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [empty_market_copy: 2]
  import AutolaunchWeb.Components.MarketCard

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(params, _uri, socket) do
    query = normalize_query(params["q"])
    auction_filter = auction_filter(params["auctions"])

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:auction_filter, auction_filter)
     |> assign_async([:auctions, :tokens], fn -> load_sections(query, auction_filter) end)}
  end

  def render(assigns) do
    ~H"""
    <main class="home-page launchpad-home">
      <section class="home-create" aria-labelledby="home-create-title">
        <h1 id="home-create-title">Create an auction</h1>
        <.link navigate={~p"/create"} class="home-create__action">Create an auction</.link>
      </section>

      <nav class="home-filters" aria-label="Market filters">
        <div class="home-filters__group">
          <p>Auctions</p>
          <.link
            patch={home_path(@search_query, :active)}
            class="home-chip"
            aria-current={if @auction_filter == :active, do: "true"}
          >
            Active
          </.link>
          <.link
            patch={home_path(@search_query, :new)}
            class="home-chip"
            aria-current={if @auction_filter == :new, do: "true"}
          >
            New
          </.link>
        </div>
        <div class="home-filters__group">
          <p>Tokens</p>
          <.link
            patch={home_path(@search_query, @auction_filter)}
            class="home-chip"
            aria-current="true"
          >
            New
          </.link>
        </div>
      </nav>

      <section id="home-auctions" class="launchpad-section" aria-labelledby="home-auctions-title">
        <header>
          <h2 id="home-auctions-title">{if @auction_filter == :new, do: "New auctions", else: "Active auctions"}</h2>
        </header>
        <p :if={@auctions.ok? && @auctions.result == []} class="launchpad-section__empty">
          {empty_market_copy(@search_query, "No auctions yet.")}
        </p>
        <div :if={@auctions.ok? && @auctions.result != []} class="launchpad-card-grid">
          <.autolaunch_market_card
            :for={auction <- @auctions.result}
            kind={:auction}
            record={auction}
          />
        </div>
      </section>

      <section id="home-tokens" class="launchpad-section" aria-labelledby="home-tokens-title">
        <header>
          <h2 id="home-tokens-title">Tokens</h2>
        </header>
        <p :if={@tokens.ok? && @tokens.result == []} class="launchpad-section__empty">
          {empty_market_copy(@search_query, "No tokens yet.")}
        </p>
        <div :if={@tokens.ok? && @tokens.result != []} class="launchpad-card-grid">
          <.autolaunch_market_card :for={token <- @tokens.result} kind={:token} record={token} />
        </div>
      </section>
    </main>
    """
  end

  defp load_sections(query, auction_filter) do
    {:ok,
     %{
       auctions: read_list(fn -> list_auctions(query, auction_filter) end),
       tokens: read_list(fn -> Autolaunch.list_graduated_launchpad_tokens(query) end)
     }}
  end

  defp list_auctions(query, :active), do: Autolaunch.list_active_launchpad_auctions(query)
  defp list_auctions("", :new), do: Autolaunch.list_recent_auctions()
  defp list_auctions(query, :new), do: Autolaunch.list_explore_launchpad_auctions(query)

  defp read_list(reader) do
    case reader.() do
      {:ok, records} -> records
      {:error, _reason} -> []
    end
  end

  defp auction_filter("new"), do: :new
  defp auction_filter(_value), do: :active

  defp normalize_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.graphemes()
    |> Enum.take(80)
    |> Enum.join()
  end

  defp normalize_query(_query), do: ""

  defp home_path(query, filter) do
    params =
      []
      |> maybe_put("q", query)
      |> maybe_put("auctions", if(filter == :new, do: "new"))

    case params do
      [] -> "/"
      params -> "/?" <> URI.encode_query(params)
    end
  end

  defp maybe_put(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put(params, key, value), do: params ++ [{key, value}]
end
