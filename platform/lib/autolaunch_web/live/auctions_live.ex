defmodule AutolaunchWeb.AuctionsLive do
  @moduledoc false
  use AutolaunchWeb, :live_view
  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.SwapModal
  import AutolaunchWeb.Components.AuctionStats

  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(trade: nil) |> assign_auction_stats()}

  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(cursor: params["after"], trade: nil) |> load_page()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}

  def handle_event("open_trade", %{"id" => id} = params, socket),
    do: {:noreply, assign(socket, :trade, opened_trade(socket.assigns.records, id, params))}

  def handle_event("open_trade", _params, socket), do: {:noreply, socket}

  def handle_event("open_robinhood_bid", %{"id" => address} = params, socket) do
    auctions = List.wrap(socket.assigns.robinhood.result)
    {:noreply, assign(socket, :trade, opened_robinhood_bid(auctions, address, params))}
  end

  def handle_event("open_robinhood_bid", _params, socket), do: {:noreply, socket}

  def handle_event("close_trade", %{"id" => id}, socket) do
    case socket.assigns.trade do
      %{record: %{id: ^id}} -> {:noreply, assign(socket, :trade, nil)}
      %{record: %{auction: ^id}} -> {:noreply, assign(socket, :trade, nil)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("close_trade", _params, socket), do: {:noreply, socket}

  defp load_page(socket) do
    cursor = socket.assigns.cursor

    assign_async(
      socket,
      [:records, :creators, :pagination, :robinhood],
      fn ->
        with {:ok, page} <- AutolaunchWeb.MarketPage.auctions(cursor, "all", "newest", 24) do
          {:ok,
           %{
             records: page.records,
             robinhood: page.robinhood,
             creators: creator_connections_for(page.records),
             pagination: page.pagination
           }}
        end
      end,
      reset: true
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
      robinhood={@robinhood}
      robinhood_trade_event="open_robinhood_bid"
    >
      <:stats>
        <.auction_stats revstake={@revstake_stats} memestake={@memestake_stats} />
      </:stats>
    </.collection>
    <.robinhood_bid_modal
      :if={match?(%{record: %{launch_id: _}}, @trade)}
      id={"auctions-robinhood-bid-#{@trade.record.auction}"}
      auction={@trade.record}
      amount={@trade.amount}
      authenticated={@account_control.kind == :signed_in}
      current_human_id={current_human_id(@access_context)}
      session_lease={@session_lease}
    />
    <.bid_modal
      :if={match?(%{record: %Autolaunch.Auction{}}, @trade)}
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
