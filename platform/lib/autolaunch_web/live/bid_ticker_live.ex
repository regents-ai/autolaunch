defmodule AutolaunchWeb.BidTickerLive do
  @moduledoc false
  use Phoenix.LiveView, layout: false
  alias Autolaunch.BidActivity

  def mount(_, _, socket) do
    if connected?(socket) do
      Autolaunch.Listings.subscribe()
      send(self(), :load)
    end

    {:ok, assign(socket, bids: [], paused: false, loading: false)}
  end

  def handle_event("pause", _, socket),
    do: {:noreply, assign(socket, paused: !socket.assigns.paused)}

  def handle_info({:autolaunch_listings_changed, _}, socket) do
    if socket.assigns.loading do
      {:noreply, socket}
    else
      Process.send_after(self(), :load, 1_000)
      {:noreply, assign(socket, loading: true)}
    end
  end

  def handle_info(:load, socket) do
    {:noreply,
     socket
     |> assign(loading: true)
     |> start_async(:bids, fn -> Ash.read(BidActivity, action: :recent, actor: nil) end)}
  end

  def handle_async(:bids, {:ok, {:ok, bids}}, socket),
    do: {:noreply, assign(socket, bids: Enum.reject(bids, &is_nil(&1.auction)), loading: false)}

  def handle_async(:bids, _, socket), do: {:noreply, assign(socket, loading: false)}

  def render(assigns) do
    ~H"""
    <aside
      :if={@bids != []}
      class={["bid-ticker", @paused && "bid-ticker--paused"]}
      aria-label="Recent confirmed bids"
    >
      <button
        type="button"
        phx-click="pause"
        class="bid-ticker__pause"
        aria-label={if @paused, do: "Resume bid ticker", else: "Pause bid ticker"}
        aria-pressed={@paused}
      >{if @paused, do: "Play", else: "Pause"}</button>
      <div class="bid-ticker__window">
        <div class="bid-ticker__track">
          <div :for={copy <- [0, 1]} class="bid-ticker__group" aria-hidden={if copy == 1, do: "true"}>
            <.link
              :for={bid <- @bids}
              navigate={path(bid.auction)}
              tabindex={if copy == 1, do: "-1"}
              class="bid-ticker__bid"
            >
              <strong>{amount(bid.display_amount, bid.display_symbol)} {bid.display_symbol} BID</strong>
              <img
                :if={bid.auction.image}
                src={bid.auction.image}
                width="24"
                height="24"
                alt=""
                loading="lazy"
              />
              <span>{bid.auction.token_symbol}</span>
            </.link>
          </div>
        </div>
      </div>
    </aside>
    """
  end

  def amount(value, "REGENT") do
    if Decimal.compare(value, Decimal.new(1_000_000)) != :lt,
      do:
        Decimal.div(value, 1_000_000)
        |> Decimal.round(1)
        |> Decimal.to_string(:normal)
        |> Kernel.<>("mil"),
      else: rounded(value, 0)
  end

  def amount(value, symbol) when symbol in ["USDC", "USDG"], do: rounded(value, 0)
  def amount(value, _), do: rounded(value, 3)
  defp rounded(value, places), do: value |> Decimal.round(places) |> Decimal.to_string(:normal)

  defp path(auction) do
    if Autolaunch.Robinhood.Lab.chain?(auction.chain_id),
      do: "/robinhood/auctions/#{auction.auction_address}",
      else: "/auctions/#{auction.id}"
  end
end
