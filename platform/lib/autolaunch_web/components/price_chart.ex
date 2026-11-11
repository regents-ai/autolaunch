defmodule AutolaunchWeb.Components.PriceChart do
  @moduledoc """
  A graduated token's price since its pool opened, as one line in the colour
  of its image, under the token's top card, with the low, the high and the
  number of trades beneath it. The figures come from `Autolaunch.PriceHistory`;
  the PriceChart hook draws the line with WebGPU. The caption says in words how
  far the price has moved, so a browser that cannot draw still reads it.

  A market's history carries two lines, one step per trade and 100 points
  evenly spread in time, and a "Trades / Time" choice picks which one the
  canvas draws. The trade line goes to the page as `[step, price]` pairs, so
  each trade takes the same width. The choice lives in the browser and
  survives the page's updates; a history whose `times` is nil, such as a
  series' prices, has no choice.

  `price_line/1` is the covered-call tickets' smaller line, with their strike
  across it.
  """
  use Phoenix.Component

  alias AutolaunchWeb.TokenDisplay

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the line is, e.g. since when"

  attr :history, :map,
    required: true,
    doc:
      "`points`, `times` (or nil), `low`, `high` and `trades`, as `Autolaunch.PriceHistory.pool/4` gives them, or nil"

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
      data-points={Jason.encode!(steps(@history.points))}
      data-times={@history.times && Jason.encode!(@history.times)}
      style={@color && "--image-color: #{@color}"}
    >
      <figcaption class="price-chart__caption">
        <span>{@label}</span>
        <span class="price-chart__change">{change(@history.points)}</span>
        <span
          :if={@history.times}
          id={"#{@id}-scale"}
          class="price-chart__scale"
          role="radiogroup"
          aria-label="Line"
          phx-update="ignore"
        >
          <label>
            <input type="radio" name={"#{@id}-scale"} value="points" checked />
            <span>Trades</span>
          </label>
          <label>
            <input type="radio" name={"#{@id}-scale"} value="times" />
            <span>Time</span>
          </label>
        </span>
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

  attr :id, :string, required: true

  attr :points, :list,
    required: true,
    doc: "`[unix seconds, dollars]` pairs, oldest first, or nil while there is no line"

  attr :follow, :string,
    default: nil,
    doc: "the Sell form whose strike the first level follows as it is chosen or typed"

  slot :level, required: true, doc: "a price drawn flat across it, its figure at the end" do
    attr :price, :float, required: true, doc: "in dollars, nil while it is not set"
    attr :name, :string, doc: "the word before its figure"
    attr :dotted, :boolean, doc: "drawn dotted and lighter, to tell it from a dashed one"
  end

  @doc """
  A covered-call ticket's small price line: a stock's last 30 days, with prices
  drawn flat across it and each one's figure at its end (the strike, and on Buy
  the break-even, each named, the break-even dotted). The PriceLine hook draws
  it with this module's renderer. Its box keeps its size while there is no
  line, and a browser that cannot draw keeps the caption.
  """
  def price_line(assigns) do
    ~H"""
    <figure id={@id} class="price-line">
      <figcaption class="price-chart__caption">
        <span>30 days</span>
        <span :if={@points} class="price-chart__change">{change(@points)}</span>
      </figcaption>
      <div
        :if={@points}
        id={"#{@id}-plot"}
        class="price-line__plot"
        phx-hook="PriceLine"
        data-points={Jason.encode!(@points)}
        data-levels={Jason.encode!(Enum.map(@level, & &1.price))}
        data-follow={@follow}
      >
        <canvas id={"#{@id}-line"} phx-update="ignore" aria-hidden="true"></canvas>
        <div id={"#{@id}-levels"} class="price-line__levels" phx-update="ignore" aria-hidden="true">
          <span
            :for={level <- @level}
            class={["price-line__level", level[:dotted] && "price-line__level--dotted"]}
            data-level=""
            hidden
          ><span><small :if={level[:name]} class="price-line__name">{level.name}</small><span data-figure></span></span></span>
        </div>
      </div>
      <div :if={!@points} id={"#{@id}-empty"} class="price-line__plot"></div>
    </figure>
    """
  end

  attr :id, :string, required: true
  attr :pool, Phoenix.LiveView.AsyncResult, required: true, doc: "the page's pool read"
  attr :color, :string, default: nil, doc: "the image colour, or nil for the plain line"

  @doc """
  A token page's chart panel: its place while the pool is first read, then the
  line since the pool opened. A read again after a trade keeps the line as it
  is until the new one arrives, and a pool with a single price shows no panel.
  """
  def pool_chart(
        %{pool: %{ok?: true, result: %{prices: %{points: [_first, _second | _rest]}}}} = assigns
      ) do
    ~H"""
    <Regent.Structure.panel class="token-page__chart">
      <.price_chart
        id={@id}
        label="Since the pool opened"
        history={@pool.result.prices}
        unit={@pool.result.currency.symbol}
        color={@color}
      />
    </Regent.Structure.panel>
    """
  end

  def pool_chart(%{pool: %{ok?: false, loading: loading}} = assigns) when loading != nil do
    ~H"""
    <Regent.Structure.panel class="token-page__chart">
      <.price_chart_reading />
    </Regent.Structure.panel>
    """
  end

  def pool_chart(assigns), do: ~H""

  # The chart's place while the pool is first read, so the card keeps its height when the line arrives.
  defp price_chart_reading(assigns) do
    ~H"""
    <div class="price-chart" role="status">
      <span class="visually-hidden">Reading the price</span>
      <span class="loading-block price-chart__caption-reading" aria-hidden="true"></span>
      <span class="loading-block price-chart__line" aria-hidden="true"></span>
      <span class="loading-block price-chart__facts-reading" aria-hidden="true"></span>
    </div>
    """
  end

  @doc "How far a line of `[block or time, price]` points moved from its first price to its last, in words."
  def change(points) do
    case move(points) do
      {:up, percent} -> "Up #{percent}%"
      {:down, percent} -> "Down #{percent}%"
      :unchanged -> "Unchanged"
    end
  end

  @doc """
  Which way a line of `[block or time, price]` points moved from its first price to its
  last, and by how many percent to one decimal place, or `:unchanged`.
  """
  def move([[_block, first] | _rest] = points) do
    [_block, last] = List.last(points)
    percent = Float.round((last / first - 1) * 100, 1)

    cond do
      percent > 0 -> {:up, percent}
      percent < 0 -> {:down, abs(percent)}
      true -> :unchanged
    end
  end

  # The trade line's prices, one step apart.
  defp steps(points), do: points |> Enum.with_index(fn [_block, price], step -> [step, price] end)

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
