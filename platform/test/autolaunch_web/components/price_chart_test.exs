defmodule AutolaunchWeb.PriceChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.Components.PriceChart
  alias Phoenix.LiveView.AsyncResult

  @history %{
    points: [[100, 1.0], [250, 2.0], [900, 1.5]],
    times: [[1_000, 1.0], [2_000, 2.0]],
    low: 1.0,
    high: 2.0,
    trades: 2
  }

  defp pool(history),
    do: %{prices: history, currency: %{symbol: "REGENT"}}

  # The trade line reaches the page one step per trade, so each trade takes the
  # same width whatever block it landed in; the time line keeps its times.
  test "the chart offers Trades and Time, the trade line spread one step per trade" do
    html =
      render_component(&PriceChart.price_chart/1,
        id: "chart",
        label: "Since the pool opened",
        history: @history,
        unit: "REGENT"
      )

    assert html =~ ~s(data-points="[[0,1.0],[1,2.0],[2,1.5]]")
    assert html =~ ~s(data-times="[[1000,1.0],[2000,2.0]]")
    assert html =~ ~s(role="radiogroup")
    assert html =~ ">Trades<" and html =~ ">Time<"
  end

  test "a history with no line by time offers no choice" do
    html =
      render_component(&PriceChart.price_chart/1,
        id: "chart",
        label: "Since the pool opened",
        history: %{@history | times: nil},
        unit: "REGENT"
      )

    assert html =~ "data-points"
    refute html =~ "data-times"
    refute html =~ "radiogroup"
  end

  # After a trade the page reads its pool again; the line stays as it is,
  # with no reading placeholder above it, until the new one arrives.
  test "a pool read again keeps its line and shows no placeholder" do
    read = AsyncResult.ok(AsyncResult.loading(), pool(@history))
    again = AsyncResult.loading(read)

    for result <- [read, again] do
      html = render_component(&PriceChart.pool_chart/1, id: "chart", pool: result)
      assert html =~ "data-points"
      refute html =~ "Reading the price"
    end
  end

  test "the first read shows the placeholder; a failed or one-price pool shows nothing" do
    first = render_component(&PriceChart.pool_chart/1, id: "chart", pool: AsyncResult.loading())
    assert first =~ "Reading the price"

    failed = AsyncResult.failed(AsyncResult.loading(), {:error, :chain_unavailable})
    assert render_component(&PriceChart.pool_chart/1, id: "chart", pool: failed) == ""

    one_price = %{@history | points: [[100, 1.0]]}
    again = AsyncResult.loading(AsyncResult.ok(AsyncResult.loading(), pool(one_price)))
    assert render_component(&PriceChart.pool_chart/1, id: "chart", pool: again) == ""
  end
end
