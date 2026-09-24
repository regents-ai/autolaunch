defmodule AutolaunchWeb.TokensLive do
  @moduledoc false
  use AutolaunchWeb, :live_view
  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.SwapModal
  alias AutolaunchWeb.LiveListings

  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(trade: nil) |> LiveListings.subscribe()}

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

  def handle_info({:autolaunch_listings_changed, _auction_id}, socket),
    do: {:noreply, LiveListings.schedule(socket)}

  # The same page and cursor are read again with the current rows left in
  # place, and an open trade keeps its form.
  def handle_info(:reread_listings, socket),
    do: {:noreply, socket |> LiveListings.taken() |> load_page(reset: false)}

  defp load_page(socket, reset: reset) do
    cursor = socket.assigns.cursor

    assign_async(
      socket,
      [:records, :creators, :pagination, :robinhood, :robinhood_unavailable],
      fn ->
        with {:ok, page} <- AutolaunchWeb.MarketPage.tokens(cursor, 24) do
          {:ok,
           %{
             records: page.records,
             robinhood: page.robinhood,
             robinhood_unavailable: page.robinhood_unavailable,
             creators: creator_connections_for(page.records ++ page.robinhood),
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
      kind={:tokens}
      records={@records}
      creators={@creators}
      pagination={@pagination}
      cursor={@cursor}
      trade_event="open_trade"
      robinhood={@robinhood}
      robinhood_unavailable={@robinhood_unavailable.ok? && @robinhood_unavailable.result}
    />
    <.swap_modal
      :if={@trade}
      id={"tokens-trade-#{@trade.record.id}"}
      token={@trade.record}
      amount={@trade.amount}
      authenticated={@account_control.kind == :signed_in}
      current_human_id={current_human_id(@access_context)}
      session_lease={@session_lease}
    />
    """
  end
end
