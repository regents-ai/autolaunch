defmodule AutolaunchWeb.AuctionsLive do
  @moduledoc """
  The auctions list: every auction as a table row with its FDV at the current
  price, bid volume and status, filtered by chain, status,
  search and the creator's verified connections. A finished auction the
  signed-in wallet has money or tokens to take from shows that press on its
  row (`AutolaunchWeb.LiveSettle`).
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.MarketCard,
    only: [auction_list: 1, assign_figure_rates: 1, list_tools: 1]

  import AutolaunchWeb.Components.AuctionStats

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  import AutolaunchWeb.Components.SwapModal, only: [settlement_modal: 1]
  alias Autolaunch.HomeMarket
  alias AutolaunchWeb.{LabMarket, LiveListings, LiveSettle}

  @all %{state: "all", sort: "newest", x: false, ens: false, github: false}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/auctions"))
     |> assign(trade: nil, all: @all)
     |> LiveListings.paged()
     |> LiveSettle.watch()
     |> LabMarket.assign_robinhood_stale()
     |> LabMarket.assign_launches_catching_up()
     |> assign_auction_stats()
     |> assign_figure_rates()}
  end

  def handle_params(params, _uri, socket) do
    options = params |> Map.put("view", "auctions") |> HomeMarket.options()
    {:noreply, socket |> assign(:pill, pill(options)) |> LiveListings.filtered(options)}
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
    do: {:noreply, socket |> LiveListings.reread() |> assign_auction_stats()}

  defp patch(socket, changes),
    do: push_patch(socket, to: list_path(socket.assigns.options, changes))

  defp list_path(options, changes), do: HomeMarket.path(options, changes, "/auctions")

  defp pill(options) do
    cond do
      options.state == "graduated" -> :graduated
      options.state == "active" and options.sort == "newest" -> :live
      options.state == "all" and not (options.x or options.ens or options.github) -> :all
      true -> nil
    end
  end

  defp verified?(options), do: options.x or options.ens or options.github

  # A search, a chain or a verified-creator choice narrows the list; a status
  # alone only picks which auctions to look at.
  defp searched?(options), do: options.q != "" or options.chain != "all" or verified?(options)

  defp empty_title("all"), do: "No auctions yet"
  defp empty_title("active"), do: "No live auctions"
  defp empty_title(_state), do: "No auctions with this status"

  defp empty_line("all"), do: "Auctions appear here once someone launches a token."
  defp empty_line("active"), do: "New auctions show here while bidding is open."
  defp empty_line(_state), do: "Try another status, or see every auction."

  # With nothing live, the way on is what already happened: graduated auctions
  # and launched tokens.
  defp empty_routes(%{state: "active"} = options, _all),
    do: [
      {list_path(options, %{state: "graduated"}), "See graduated auctions"},
      {"/tokens", "See tokens"}
    ]

  defp empty_routes(options, all), do: [{list_path(options, all), "See every auction"}]

  def render(assigns) do
    ~H"""
    <div class="autolaunch-page market-list-page" id="auctions-list">
      <.auction_stats revstake={@revstake_stats} memestock={@memestock_stats} />
      <header class="market-list__header">
        <h1 id="auctions-list-title">Auctions</h1>
        <Regent.Primitives.button
          :if={Autolaunch.Prelaunch.read_only?()}
          disabled
          title="Opens soon"
        >Launch auction</Regent.Primitives.button>
        <.link
          :if={!Autolaunch.Prelaunch.read_only?()}
          navigate="/create"
          class="rg-button rg-button--primary"
        ><span class="rg-button__label">Launch auction</span></.link>
      </header>

      <.list_tools kind="auctions" options={@options} />

      <nav class="market-list__pills" aria-label="Quick filters">
        <.link patch={list_path(@options, @all)} aria-current={if @pill == :all, do: "page"}>All</.link>
        <.link
          patch={list_path(@options, %{state: "active", sort: "newest"})}
          aria-current={if @pill == :live, do: "page"}
        >Live</.link>
        <.link
          patch={list_path(@options, %{state: "graduated"})}
          aria-current={if @pill == :graduated, do: "page"}
        >Graduated</.link>
      </nav>

      <section
        id="auctions-market"
        class="market-list"
        aria-labelledby="auctions-list-title"
        aria-busy={to_string(@loading)}
      >
        <Regent.Primitives.notice :if={@launches_catching_up?} role="status">
          <p>Catching up with the chain. Recent activity may take a moment to appear.</p>
        </Regent.Primitives.notice>
        <Regent.Primitives.notice :if={@robinhood_stale?} role="status">
          <p>Robinhood could not be read just now, so its auctions show what was last read.</p>
        </Regent.Primitives.notice>
        <p :if={@loading} class="visually-hidden" role="status">Loading auctions</p>

        <.auction_list
          :if={@records != [] or @loading}
          creators={@creators}
          records={@records}
          rates={@rates}
          loading={@loading}
          settle={@settle_labels}
        />

        <Regent.Primitives.notice :if={@failed} tone="error">
          <p>
            {if @append,
              do: "More auctions could not be loaded. The ones shown are still here.",
              else: "Auctions are unavailable right now."}
          </p>
          <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
        </Regent.Primitives.notice>

        <div :if={!@loading && !@failed && @records == []} class="market-list__empty" role="status">
          <%= if searched?(@options) do %>
            <h2>No matching auctions</h2>
            <p>Try a different search, or clear your filters.</p>
            <.link
              patch={list_path(@options, Map.merge(@all, %{q: "", chain: "all"}))}
              class="rg-button rg-button--secondary"
            >Clear filters</.link>
          <% else %>
            <h2>{empty_title(@options.state)}</h2>
            <p>{empty_line(@options.state)}</p>
            <div :if={@options.state != "all"} class="market-list__routes">
              <.link
                :for={{path, label} <- empty_routes(@options, @all)}
                navigate={path}
                class="rg-button rg-button--secondary"
              >{label}</.link>
            </div>
            <.link
              :if={@options.state == "all" && !Autolaunch.Prelaunch.read_only?()}
              navigate="/create"
              class="rg-button rg-button--secondary"
            >Launch auction</.link>
            <.link
              :if={@options.state == "all" && Autolaunch.Prelaunch.read_only?()}
              navigate="/how-it-works"
              class="rg-button rg-button--secondary"
            >How it works</.link>
          <% end %>
        </div>

        <div :if={@has_more && !@failed} class="market-list__more">
          <Regent.Primitives.button phx-click="load-more" disabled={@loading} variant="secondary">
            {if @loading, do: "Loading…", else: "Load more"}
          </Regent.Primitives.button>
        </div>
      </section>
      <.settlement_modal
        :if={@trade}
        id={"auctions-settle-#{@trade.position.id}"}
        position={@trade.position}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
    </div>
    """
  end
end
