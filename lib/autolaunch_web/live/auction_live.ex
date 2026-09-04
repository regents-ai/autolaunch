defmodule AutolaunchWeb.AuctionLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.MarketCard

  alias Autolaunch.Lab
  alias Autolaunch.LabMarketFeed

  def mount(%{"auction_id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:record_id, id)
     |> assign_market()
     |> assign_async(:page, fn -> load_auction_page(id) end)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_info({:autolaunch_market_updated, %{generation: generation}}, socket) do
    id = socket.assigns.record_id
    current = socket.assigns.market.generation

    if generation > current do
      {:noreply,
       socket
       |> assign(:market, LabMarketFeed.snapshot())
       |> assign_async(:page, fn -> load_auction_page(id) end)}
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
        page_status: page_status(assigns.page, :empty),
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
      <div id="autolaunch-bid"></div>
      <div :if={@local_lab?} id="autolaunch-lab-position"></div>
    </article>

    <section
      :if={@page_status == :empty}
      id="autolaunch-auction-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <h1>Auction not found</h1>
      <p>No public auction exists at {@record_id}.</p>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>
    """
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
