defmodule AutolaunchWeb.Components.PriceChart do
  @moduledoc """
  A graduated token's price since its pool opened, as one line in the colour
  of its image, under the token's top card, with the low, the high and the
  number of trades beneath it. The figures come from `Autolaunch.PriceHistory`;
  the PriceChart hook draws the line with WebGPU. The caption says in words how
  far the price has moved, so a browser that cannot draw still reads it.
  """
  use Phoenix.Component

  alias AutolaunchWeb.TokenDisplay

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the line is, e.g. since when"
  attr :history, :map, required: true, doc: "from `Autolaunch.PriceHistory.pool/4`, or nil"
  attr :unit, :string, required: true, doc: "the currency the price is in"
  attr :color, :string, default: nil, doc: "the image colour, or nil for the plain line"
  attr :count_label, :string, default: "Trades", doc: "what the history's count counts"

  # One point is a price, not a line.
  def price_chart(%{history: %{points: [_first, _second | _rest]}} = assigns) do
    ~H"""
    <figure
      id={@id}
      class="price-chart"
      phx-hook="PriceChart"
      data-points={Jason.encode!(@history.points)}
      style={@color && "--image-color: #{@color}"}
    >
      <figcaption class="price-chart__caption">
        <span>{@label}</span>
        <span class="price-chart__change">{change(@history.points)}</span>
      </figcaption>
      <canvas id={"#{@id}-line"} class="price-chart__line" phx-update="ignore" aria-hidden="true"></canvas>
      <dl class="price-chart__facts">
        <div>
          <dt>Low</dt>
          <dd><TokenDisplay.price amount={plain(@history.low)} unit={@unit} /></dd>
        </div>
        <div>
          <dt>High</dt>
          <dd><TokenDisplay.price amount={plain(@history.high)} unit={@unit} /></dd>
        </div>
        <div>
          <dt>{@count_label}</dt>
          <dd>{@history.trades}</dd>
        </div>
      </dl>
    </figure>
    """
  end

  def price_chart(assigns), do: ~H""

  @doc "The chart's place while the pool is first read, so the card keeps its height when the line arrives."
  def price_chart_reading(assigns) do
    ~H"""
    <div class="price-chart" role="status">
      <span class="visually-hidden">Reading the price</span>
      <span class="loading-block price-chart__caption-reading" aria-hidden="true"></span>
      <span class="loading-block price-chart__line" aria-hidden="true"></span>
      <span class="loading-block price-chart__facts-reading" aria-hidden="true"></span>
    </div>
    """
  end

  @doc "How far a line of `[block, price]` points moved from its first price to its last, in words."
  def change([[_block, first] | _rest] = points) do
    [_block, last] = List.last(points)
    percent = Float.round((last / first - 1) * 100, 1)

    cond do
      percent > 0 -> "Up #{percent}%"
      percent < 0 -> "Down #{abs(percent)}%"
      true -> "Unchanged"
    end
  end

  # A float price to six significant digits, which drops its binary noise.
  defp plain(price) do
    decimal = Decimal.from_float(price)
    %Decimal{coef: coef, exp: exp} = Decimal.normalize(decimal)

    decimal
    |> Decimal.round(6 - length(Integer.digits(coef)) - exp)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end
end
