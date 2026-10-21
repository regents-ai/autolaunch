defmodule AutolaunchWeb.Components.TokenFigures do
  @moduledoc """
  The first figures on a token's page, before its chart and its trade widget:
  its price, its market cap and how far its price has moved since its pool
  opened. The price and the market cap are in dollars where the token's
  currency has a dollar price, the price in the currency under it; otherwise
  both are in the currency. The figures settle in one after another as they
  arrive (`MotionCascade`).
  """
  use Phoenix.Component

  alias AutolaunchWeb.Components.{MarketCard, PriceChart}
  alias AutolaunchWeb.{Motion, TokenDisplay}
  alias Phoenix.LiveView.AsyncResult

  attr :id, :string, required: true
  attr :price, :string, default: nil, doc: "the stored price per token, in the currency"
  attr :market_cap, :any, default: nil, doc: "the price times the whole supply, in the currency"
  attr :unit, :string, default: nil, doc: "the currency the token trades against"

  attr :rate, AsyncResult,
    required: true,
    doc: "the currency's dollar price, as `UsdValue` reads it"

  attr :pool, AsyncResult, required: true, doc: "the token's pool as the page reads it"

  def token_figures(assigns) do
    rate = dollar_rate(assigns.rate)

    assigns =
      assign(assigns,
        rate: rate,
        market_cap: MarketCard.money(assigns.market_cap, rate, assigns.unit),
        change: change(assigns.pool)
      )

    ~H"""
    <dl
      id={@id}
      class="token-figures"
      phx-hook="MotionCascade"
      data-variant={Motion.standard("grid")}
    >
      <div class="token-figures__price">
        <dt>Price</dt>
        <dd>
          <strong>
            <MarketCard.price_figure amount={@price} unit={@unit} rate={@rate} />
            <span :if={!@price}>No price yet</span>
          </strong>
          <small :if={@price && @rate}><TokenDisplay.price amount={@price} unit={@unit} /></small>
        </dd>
      </div>
      <div>
        <dt>Market cap</dt>
        <dd><strong>{@market_cap || "No price yet"}</strong></dd>
      </div>
      <div>
        <dt>Change</dt>
        <dd>
          <strong>{@change}</strong>
          <small :if={@change not in ["No trades yet", "…"]}>since the pool opened</small>
        </dd>
      </div>
    </dl>
    """
  end

  # How far the price has moved since the pool opened, once the pool is read.
  defp change(%AsyncResult{ok?: true, result: %{prices: %{points: points}}}),
    do: PriceChart.change(points)

  defp change(%AsyncResult{ok?: true}), do: "No trades yet"
  defp change(_reading), do: "…"

  # A test network's coins, or a currency whose price is still being read,
  # show in the currency itself.
  defp dollar_rate(%AsyncResult{ok?: true, result: %Decimal{} = rate}), do: rate
  defp dollar_rate(_rate), do: nil
end
