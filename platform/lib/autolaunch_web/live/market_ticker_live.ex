defmodule AutolaunchWeb.MarketTickerLive do
  @moduledoc false
  use Phoenix.LiveView, layout: false
  alias Autolaunch.{BidActivity, TokenTrade}
  alias AutolaunchWeb.Components.MarketCard

  def mount(_, _, socket) do
    if connected?(socket) do
      Autolaunch.Listings.subscribe()
      Autolaunch.TokenTrades.subscribe()
      send(self(), :load)
    end

    {:ok,
     socket
     |> assign(entries: [], paused: false, loading: false)
     |> MarketCard.assign_figure_rates()}
  end

  def handle_event("pause", _, socket),
    do: {:noreply, assign(socket, paused: !socket.assigns.paused)}

  def handle_info({event, _}, socket)
      when event in [:autolaunch_listings_changed, :autolaunch_trade] do
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
     |> start_async(:entries, fn ->
       with {:ok, bids} <- Ash.read(BidActivity, action: :recent, actor: nil),
            {:ok, trades} <- Ash.read(TokenTrade, action: :recent, actor: nil),
            do: {:ok, entries(bids, trades)}
     end)}
  end

  def handle_async(:entries, {:ok, {:ok, entries}}, socket),
    do: {:noreply, assign(socket, entries: entries, loading: false)}

  def handle_async(:entries, _, socket), do: {:noreply, assign(socket, loading: false)}

  # Bids and trades together, newest first.
  defp entries(bids, trades) do
    bids = for %{auction: %{}} = bid <- bids, do: {:bid, bid}
    trades = for %{token: %{auction: %{}}} = trade <- trades, do: {:trade, trade}

    Enum.sort_by(bids ++ trades, fn {_, entry} -> entry.occurred_at end, {:desc, DateTime})
  end

  def render(assigns) do
    ~H"""
    <aside
      :if={@entries != []}
      class={["market-ticker", @paused && "market-ticker--paused"]}
      aria-label="Recent bids and trades"
    >
      <button
        type="button"
        phx-click="pause"
        class="market-ticker__pause"
        aria-label={
          if @paused, do: "Resume recent bids and trades", else: "Pause recent bids and trades"
        }
        aria-pressed={to_string(@paused)}
      >{if @paused, do: "Play", else: "Pause"}</button>
      <div class="market-ticker__window">
        <div class="market-ticker__track">
          <div
            :for={copy <- [0, 1]}
            class="market-ticker__group"
            aria-hidden={if copy == 1, do: "true"}
          >
            <.entry :for={entry <- @entries} entry={entry} rates={@rates} copy={copy} />
          </div>
        </div>
      </div>
    </aside>
    """
  end

  attr :entry, :any, required: true
  attr :rates, :any, required: true
  attr :copy, :integer, required: true

  defp entry(%{entry: {:bid, bid}} = assigns) do
    assigns = assign(assigns, bid: bid, fdv: max_fdv(bid, assigns.rates))

    ~H"""
    <.link
      navigate={auction_path(@bid.auction)}
      tabindex={if @copy == 1, do: "-1"}
      class="market-ticker__entry market-ticker__entry--bid"
    >
      <strong>{short(@bid.display_amount)} {@bid.display_symbol}</strong>
      <span :if={@fdv}>@ {@fdv} FDV ·</span>
      <.token_mark auction={@bid.auction} />
    </.link>
    """
  end

  defp entry(%{entry: {:trade, trade}} = assigns) do
    assigns =
      assign(assigns, trade: trade, verb: if(trade.side == :buy, do: "bought", else: "sold"))

    ~H"""
    <.link
      navigate={token_path(@trade.token)}
      tabindex={if @copy == 1, do: "-1"}
      class={["market-ticker__entry", "market-ticker__entry--#{@trade.side}"]}
    >
      <strong>{short(@trade.currency_amount)} {@trade.currency_symbol} {@verb}</strong>
      <.token_mark auction={@trade.token.auction} />
    </.link>
    """
  end

  attr :auction, :any, required: true

  defp token_mark(assigns) do
    ~H"""
    <img :if={@auction.image} src={@auction.image} width="24" height="24" alt="" loading="lazy" />
    <span>{@auction.token_symbol}</span>
    """
  end

  # Three significant digits with a short suffix: 2.37, 59, 67.6k, 1.2M.
  defp short(value), do: value |> MarketCard.compact() |> String.replace_suffix("K", "k")

  # The bid's maximum price for the whole token, in dollars at the auction
  # currency's market price; left out while no price is known.
  defp max_fdv(%{max_fdv: %Decimal{} = fdv} = bid, rates) do
    case MarketCard.figure_rate(rates, bid.auction) do
      %Decimal{} = rate -> fdv |> Decimal.mult(rate) |> short()
      nil -> nil
    end
  end

  defp max_fdv(_bid, _rates), do: nil

  defp auction_path(auction) do
    if Autolaunch.Robinhood.Lab.chain?(auction.chain_id),
      do: "/robinhood/auctions/#{auction.auction_address}",
      else: "/auctions/#{auction.id}"
  end

  defp token_path(%{auction: auction} = token) do
    if Autolaunch.Robinhood.Lab.chain?(auction.chain_id),
      do: "/robinhood/tokens/#{auction.token_address}",
      else: "/tokens/#{token.id}"
  end
end
