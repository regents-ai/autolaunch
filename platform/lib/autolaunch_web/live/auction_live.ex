defmodule AutolaunchWeb.AuctionLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.MarketCard

  alias Autolaunch.Lab
  alias Autolaunch.LabMarketFeed

  def mount(_params, _session, socket), do: {:ok, assign_market(socket)}

  # The identifier is read here so a patch to another auction reloads the page
  # instead of keeping the previous record on screen.
  def handle_params(%{"auction_id" => id}, _uri, socket) do
    {:noreply, socket |> assign(:record_id, id) |> load_page(reset: true)}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket, reset: true)}

  def handle_info({:autolaunch_market_updated, %{generation: generation}}, socket) do
    if generation > socket.assigns.market.generation do
      {:noreply,
       socket
       |> assign(:market, LabMarketFeed.snapshot())
       |> load_page(reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:autolaunch_market_updated, _update}, socket), do: {:noreply, socket}

  def render(assigns) do
    assigns =
      assign(assigns,
        local_lab?: Lab.enabled?(),
        page_record: page_record(assigns.page),
        page_status: page_status(assigns.page, :error),
        creator_connections: page_connections(assigns.page)
      )

    assigns =
      assign(
        assigns,
        :market_snapshot,
        auction_market_snapshot(assigns.market, assigns.page_record)
      )

    ~H"""
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-auction-detail"
      class="autolaunch-page"
    >
      <header class="autolaunch-heading">
        <p class="autolaunch-kicker">
          <%= if @local_lab? do %>
            Local Base fork · test assets · no mainnet value
          <% else %>
            Autolaunch · Auction
          <% end %>
        </p>
        <h1>{record_label(:auction, @page_record)}</h1>
        <p>{record_summary(:auction, @page_record) || record_fallback(:auction)}</p>
      </header>
      <.autolaunch_market_card
        kind={:auction}
        record={@page_record}
        creator_connections={@creator_connections}
        linked={false}
        class="launchpad-card--detail"
      />
      <.treasury_security
        :if={!@local_lab?}
        report={report(@page_record)}
        surface="auction-detail"
      />
      <dl :if={@local_lab? && @market_snapshot} class="autolaunch-live-market">
        <div>
          <dt>Local block</dt><dd>{@market_snapshot.block_number}</dd>
        </div>
        <div>
          <dt>REGENT raised</dt><dd>{@market_snapshot.currency_raised}</dd>
        </div>
        <div>
          <dt>Tokens remaining</dt><dd>{@market_snapshot.remaining_supply}</dd>
        </div>
        <div>
          <dt>Claim block</dt><dd>{@market_snapshot.claim_block}</dd>
        </div>
      </dl>
      <.live_component
        module={AutolaunchWeb.BidComponent}
        id="autolaunch-bid"
        auction={@page_record}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <div :if={@local_lab?} id="autolaunch-lab-position"></div>
    </article>

    <p :if={@page_status == :loading} class="autolaunch-page" role="status">Loading…</p>

    <section
      :if={@page_status == :empty}
      id="autolaunch-auction-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <h1>Auction not found</h1>
      <p>No public auction exists at {@record_id}.</p>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>

    <section
      :if={@page_status == :error}
      id="autolaunch-auction-detail"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <h1>Auction unavailable</h1>
      <p>This auction could not be loaded right now.</p>
      <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>
    """
  end

  defp load_page(socket, reset: reset) do
    id = socket.assigns.record_id
    assign_async(socket, :page, fn -> load_auction_page(id) end, reset: reset)
  end

  defp assign_market(socket) do
    if connected?(socket) and Lab.enabled?() and Process.whereis(LabMarketFeed) do
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())
      assign(socket, :market, LabMarketFeed.snapshot())
    else
      assign(socket, :market, empty_market())
    end
  end
end
