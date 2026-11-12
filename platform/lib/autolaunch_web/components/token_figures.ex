defmodule AutolaunchWeb.Components.TokenFigures do
  @moduledoc """
  A token page's figures. `token_figures/1` opens the page: the price, large,
  with how far it has moved since its pool opened beside it and the price in
  the token's currency under it. `market_stats/1` follows the chart: the market
  cap, the price in the currency, the change, the total supply, the number of
  trades and the launch type. Dollar figures are shown where the token's
  currency has a dollar price; otherwise every figure is in the currency. The
  figures settle in one after another as they arrive (`MotionCascade`).
  """
  use Phoenix.Component

  alias AutolaunchWeb.Components.{LaunchTrust, MarketCard, PriceChart}
  alias AutolaunchWeb.{Motion, TokenDisplay}
  alias Phoenix.LiveView.AsyncResult

  attr :id, :string, required: true
  attr :price, :string, default: nil, doc: "the stored price per token, in the currency"
  attr :unit, :string, default: nil, doc: "the currency the token trades against"

  attr :rate, AsyncResult,
    required: true,
    doc: "the currency's dollar price, as `UsdValue` reads it"

  attr :pool, AsyncResult, required: true, doc: "the token's pool as the page reads it"

  def token_figures(assigns) do
    assigns = assign(assigns, rate: dollar_rate(assigns.rate), move: direction(assigns.pool))

    ~H"""
    <div
      id={@id}
      class="token-figures"
      phx-hook="MotionCascade"
      data-variant={Motion.standard("grid")}
    >
      <p class="token-figures__price">
        <strong>
          <MarketCard.price_figure amount={@price} unit={@unit} rate={@rate} />
          <span :if={!@price}>No price yet</span>
        </strong>
        <.move move={@move} />
      </p>
      <p :if={@price && @rate} class="token-figures__unit">
        <TokenDisplay.price amount={@price} unit={@unit} />
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :auction, :map, required: true, doc: "the token's auction, for its supply and launch type"
  attr :price, :string, default: nil
  attr :market_cap, :any, default: nil, doc: "the price times the whole supply, in the currency"
  attr :unit, :string, default: nil
  attr :rate, AsyncResult, required: true
  attr :pool, AsyncResult, required: true

  def market_stats(assigns) do
    rate = dollar_rate(assigns.rate)

    assigns =
      assign(assigns,
        market_cap: MarketCard.money(assigns.market_cap, rate, assigns.unit),
        change: change(assigns.pool),
        trades: trades(assigns.pool),
        supply: assigns.auction.token_supply && RegentFormat.amount(assigns.auction.token_supply),
        launch_type: LaunchTrust.launch_type(assigns.auction)
      )

    ~H"""
    <section class="token-market" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="token-page__title">Market</h2>
      <dl id={@id} class="token-market__stats">
        <div>
          <dt>Market cap</dt>
          <dd class="rg-figure">{@market_cap || "No price yet"}</dd>
        </div>
        <div>
          <dt>Price in {@unit}</dt>
          <dd class="rg-figure"><TokenDisplay.price amount={@price} /></dd>
        </div>
        <div>
          <dt>Change</dt>
          <dd class="rg-figure">{@change}</dd>
        </div>
        <div>
          <dt>Total supply</dt>
          <dd class="rg-figure">{@supply || "Not read yet"}</dd>
        </div>
        <div>
          <dt>Trades</dt>
          <dd class="rg-figure">{@trades}</dd>
        </div>
        <div>
          <dt>Launch type</dt>
          <dd>{@launch_type}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :move, :any, required: true

  # The change since the pool opened as a small tinted chip: the arrow and the
  # percent, with the direction in words for a screen reader.
  defp move(%{move: {direction, percent}} = assigns) when direction in [:up, :down] do
    assigns = assign(assigns, direction: direction, percent: percent)

    ~H"""
    <span class={["token-figures__move", "token-figures__move--#{@direction}"]}>
      <Regent.Icons.icon name={if @direction == :up, do: "trending-up", else: "trending-down"} />
      <span class="visually-hidden">{if @direction == :up, do: "Up", else: "Down"}</span>
      {@percent}%
    </span>
    """
  end

  defp move(assigns), do: ~H""

  defp direction(%AsyncResult{ok?: true, result: %{prices: %{points: points}}}),
    do: PriceChart.move(points)

  defp direction(_pool), do: nil

  # How far the price has moved since the pool opened, once the pool is read.
  defp change(%AsyncResult{ok?: true, result: %{prices: %{points: points}}}),
    do: PriceChart.change(points)

  defp change(%AsyncResult{ok?: true}), do: "No trades yet"
  defp change(_reading), do: "…"

  defp trades(%AsyncResult{ok?: true, result: %{prices: %{trades: trades}}}), do: trades
  defp trades(%AsyncResult{ok?: true}), do: 0
  defp trades(_reading), do: "…"

  # A test network's coins, or a currency whose price is still being read,
  # show in the currency itself.
  defp dollar_rate(%AsyncResult{ok?: true, result: %Decimal{} = rate}), do: rate
  defp dollar_rate(_rate), do: nil
end
