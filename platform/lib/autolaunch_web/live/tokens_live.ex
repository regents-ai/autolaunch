defmodule AutolaunchWeb.TokensLive do
  @moduledoc """
  The tokens list: every launched token as a table row with its price, market
  cap and when it launched, filtered by chain, search and the creator's
  verified connections.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.MarketCard,
    only: [token_list: 1, assign_figure_rates: 1, list_tools: 1]

  alias Autolaunch.HomeMarket
  alias AutolaunchWeb.{LabMarket, LiveListings}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/tokens"))
     |> LiveListings.paged()
     |> LabMarket.assign_robinhood_stale()
     |> LabMarket.assign_launches_catching_up()
     |> assign_figure_rates()}
  end

  def handle_params(params, _uri, socket) do
    options = params |> Map.put("view", "tokens") |> HomeMarket.options()
    {:noreply, LiveListings.filtered(socket, options)}
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
    do: {:noreply, LiveListings.load(socket, true)}

  def handle_event("load-more", _params, socket), do: {:noreply, socket}

  def handle_event("retry", _params, socket),
    do: {:noreply, LiveListings.load(socket, socket.assigns.append)}

  # The Robinhood notice follows whether the site could read Robinhood.
  def handle_info({:shared_reading, {:chain_head, "robinhood"}}, socket),
    do: {:noreply, LabMarket.robinhood_stale(socket)}

  # The catching-up notice follows whether the lists hold every Base launch.
  def handle_info({:shared_reading, {:launch_count, _launchpad}}, socket),
    do: {:noreply, LabMarket.launches_catching_up(socket)}

  def handle_info({:autolaunch_listings_changed, _auction_id}, socket),
    do: {:noreply, LiveListings.schedule(socket)}

  def handle_info(:reread_listings, socket),
    do: {:noreply, LiveListings.reread(socket)}

  defp patch(socket, changes),
    do: push_patch(socket, to: list_path(socket.assigns.options, changes))

  defp list_path(options, changes), do: HomeMarket.path(options, changes, "/tokens")

  defp filtered?(options),
    do: options.q != "" or options.chain != "all" or options.x or options.ens or options.github

  def render(assigns) do
    ~H"""
    <div class="autolaunch-page market-list-page" id="tokens-list">
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
        <Regent.Primitives.notice :if={@launches_catching_up?} role="status">
          <p>Catching up with the chain. Recent activity may take a moment to appear.</p>
        </Regent.Primitives.notice>
        <Regent.Primitives.notice :if={@robinhood_stale?} role="status">
          <p>Robinhood could not be read just now, so its tokens show what was last read.</p>
        </Regent.Primitives.notice>
        <p :if={@loading} class="visually-hidden" role="status">Loading tokens</p>

        <.token_list
          :if={@records != [] or @loading}
          creators={@creators}
          records={@records}
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
    </div>
    """
  end
end
