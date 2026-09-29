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
      <header class="home-explore rg-hero">
        <div class="rg-hero__copy">

        <p class="home-explore__kicker">Autolaunch</p>
        <Regent.Structure.section_bar><h1 class="rg-section-bar__label" id="home-explore-title">Explore coins</h1></Regent.Structure.section_bar>
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
          <.link navigate={~p"/create"} class="rg-button rg-button--primary home-create"><span class="rg-button__label">Create</span></.link>
        </nav>
        <.regent_market_links />
        </div>
        <div class="rg-hero__figure">
          <Regent.Structure.technical_figure class="rg-support-figure home-figure">
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
            <:caption>Autolaunch · Illustration</:caption>
          </Regent.Structure.technical_figure>
        </div>
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
      <section class="home-capabilities" aria-labelledby="home-workflows-title">
        <Regent.Structure.section_bar class="rg-support-band">
          <h2 id="home-workflows-title" class="rg-section-bar__label">Launch, bid, follow</h2>
        </Regent.Structure.section_bar>
        <div class="rg-feature-grid">
          <Regent.Structure.capability_card title="Launch an auction" description="Save token details privately, choose treasury custody, then review the exact transactions with your wallet." index="01">
            <:media>
              <svg viewBox="0 0 240 240" fill="none" stroke="currentColor" aria-hidden="true"><path d="M40 192h160M64 192v-48h32v48m16 0V96h32v96m16 0V48h32v144M48 64l32-24 24 16 40-24" /></svg>
            </:media>
            <:actions><.link navigate="/create" class="rg-button rg-button--primary"><span class="rg-button__label">Create a launch</span></.link></:actions>
          </Regent.Structure.capability_card>
          <Regent.Structure.capability_card title="Bid with REGENT" description="Explore auctions and review a bid. Your selected wallet confirms every onchain step." index="02">
            <:media>
              <svg viewBox="0 0 240 240" fill="none" stroke="currentColor" aria-hidden="true"><circle cx="120" cy="120" r="72"/><circle cx="120" cy="120" r="40"/><path d="M24 120h192M120 24v192M48 48l144 144"/></svg>
            </:media>
            <:actions><.link navigate="/auctions" class="rg-button rg-button--secondary">Browse auctions</.link></:actions>
          </Regent.Structure.capability_card>
          <Regent.Structure.capability_card title="Follow your positions" description="See bids, returnable positions and held launch tokens from your verified wallets." index="03">
            <:media>
              <svg viewBox="0 0 240 240" fill="none" stroke="currentColor" aria-hidden="true"><path d="M48 40h144v160H48zM48 80h144M48 120h144M48 160h144M96 40v160M144 40v160"/><path d="m60 102 8 8 16-20m24 62 8-8 16 16"/></svg>
            </:media>
            <:actions><.link navigate="/portfolio" class="rg-button rg-button--secondary">View portfolio</.link></:actions>
          </Regent.Structure.capability_card>
        </div>
        <p class="autolaunch-micro">Illustrations · Transactions remain wallet-confirmed</p>
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
