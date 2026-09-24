defmodule AutolaunchWeb.AuctionsLive do
  @moduledoc false
  use AutolaunchWeb, :live_view
  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.SwapModal
  import AutolaunchWeb.Components.AuctionStats
  alias AutolaunchWeb.{LabMarket, LiveListings}

  def mount(_params, _session, socket),
    do:
      {:ok,
       socket
       |> assign(trade: nil, market: LabMarket.subscribe(socket))
       |> LiveListings.subscribe()
       |> assign_auction_stats()}

  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(cursor: params["after"], trade: nil) |> load_page(reset: true)}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket, reset: true)}

  def handle_event("open_trade", %{"id" => id} = params, socket),
    do: {:noreply, assign(socket, :trade, opened_trade(socket.assigns.records, id, params))}

  def handle_event("open_trade", _params, socket), do: {:noreply, socket}

  def handle_event("close_trade", %{"id" => id}, socket) do
    case socket.assigns.trade do
      %{record: %{id: ^id}} -> {:noreply, assign(socket, :trade, nil)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("close_trade", _params, socket), do: {:noreply, socket}

  # A market feed read the auctions again: the amounts raised on the cards
  # follow it, and the Robinhood notice follows whether Robinhood could be read.
  def handle_info({:autolaunch_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def handle_info({:robinhood_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def handle_info({:autolaunch_listings_changed, _auction_id}, socket),
    do: {:noreply, LiveListings.schedule(socket)}

  # The same page and cursor are read again with the current records left in
  # place, and an open bid keeps its form.
  def handle_info(:reread_listings, socket),
    do:
      {:noreply,
       socket |> LiveListings.taken() |> load_page(reset: false) |> assign_auction_stats()}

  defp load_page(socket, reset: reset) do
    cursor = socket.assigns.cursor

    assign_async(
      socket,
      [:records, :creators, :pagination],
      fn ->
        with {:ok, page} <- AutolaunchWeb.MarketPage.auctions(cursor, "all", "newest", 24) do
          {:ok,
           %{
             records: page.records,
             creators: creator_connections_for(page.records),
             pagination: page.pagination
           }}
        end
      end,
      reset: reset
    )
  end

  def render(assigns) do
    ~H"""
    <.collection
      kind={:auctions}
      records={@records}
      creators={@creators}
      pagination={@pagination}
      cursor={@cursor}
      trade_event="open_trade"
      robinhood_unavailable={@market.robinhood_stale?}
      market={@market}
    >
      <:stats>
        <.auction_stats revstake={@revstake_stats} memestake={@memestake_stats} />
      </:stats>
    </.collection>
    <.robinhood_bid_modal
      :if={@trade && robinhood?(@trade.record)}
      id={"auctions-robinhood-bid-#{@trade.record.id}"}
      auction={@trade.record}
      amount={@trade.amount}
      authenticated={@account_control.kind == :signed_in}
      current_human_id={current_human_id(@access_context)}
      session_lease={@session_lease}
    />
    <.bid_modal
      :if={@trade && !robinhood?(@trade.record)}
      id={"auctions-bid-#{@trade.record.id}"}
      auction={@trade.record}
      amount={@trade.amount}
      authenticated={@account_control.kind == :signed_in}
      current_human_id={current_human_id(@access_context)}
      session_lease={@session_lease}
    />
    """
  end
end
