defmodule AutolaunchWeb.MarketTickerLive do
  @moduledoc false
  use Phoenix.LiveView, layout: false
  alias AutolaunchWeb.Components.MarketCard
  alias AutolaunchWeb.Paths

  # Every open page shares the one list `Autolaunch.MarketTicker` keeps.
  def mount(_, _, socket) do
    entries = if connected?(socket), do: Autolaunch.MarketTicker.subscribe(), else: []

    {:ok,
     socket
     |> assign(entries: entries, paused: false)
     |> MarketCard.assign_figure_rates()}
  end

  def handle_event("pause", _, socket),
    do: {:noreply, assign(socket, paused: !socket.assigns.paused)}

  def handle_info({:market_ticker, entries}, socket),
    do: {:noreply, assign(socket, entries: entries)}

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
      navigate={Paths.auction(@bid.auction)}
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
      navigate={Paths.token(@trade.token.auction)}
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
end
