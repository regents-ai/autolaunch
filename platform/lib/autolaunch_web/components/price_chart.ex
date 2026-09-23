defmodule AutolaunchWeb.Components.PriceChart do
  @moduledoc """
  A launch's price over time as one line in the colour of its image, under
  the launch's top card. The points come from `Autolaunch.PriceHistory`; the
  PriceChart hook draws them with WebGPU. The caption says in words how far
  the price has moved, so a browser that cannot draw still reads it.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the line is, e.g. since when"
  attr :points, :list, required: true, doc: "`[block, price]` pairs in block order"
  attr :color, :string, default: nil, doc: "the image colour, or nil for the plain line"

  # One point is a price, not a line.
  def price_chart(%{points: [_first, _second | _rest]} = assigns) do
    ~H"""
    <figure
      id={@id}
      class="price-chart"
      phx-hook="PriceChart"
      data-points={Jason.encode!(@points)}
      style={@color && "--image-color: #{@color}"}
    >
      <figcaption class="price-chart__caption">
        <span>{@label}</span>
        <span class="price-chart__change">{change(@points)}</span>
      </figcaption>
      <canvas id={"#{@id}-line"} class="price-chart__line" phx-update="ignore" aria-hidden="true"></canvas>
    </figure>
    """
  end

  def price_chart(assigns), do: ~H""

  defp change([[_block, first] | _rest] = points) do
    [_block, last] = List.last(points)
    percent = Float.round((last / first - 1) * 100, 1)

    cond do
      percent > 0 -> "Up #{percent}%"
      percent < 0 -> "Down #{abs(percent)}%"
      true -> "Unchanged"
    end
  end
end
