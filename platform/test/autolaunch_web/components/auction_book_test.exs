defmodule AutolaunchWeb.AuctionBookTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.Components.AuctionBook

  # MINIMUM_SHORTFALL_NEVER_UNDERSTATED: the line under a bid in an auction short of
  # its minimum says how much is still missing. Showing every amount the one
  # Regent way cut the figure down, so 1,234.567 missing read "1,234.56" and a
  # bidder was told less was missing than is (27 Oct 2026). The shown figure is
  # rounded up at the places every amount is shown to.
  property "MINIMUM_SHORTFALL_NEVER_UNDERSTATED" do
    check all(
            coef <- integer(1..1_000_000_000_000_000_000_000),
            places <- integer(0..18)
          ) do
      missing = Decimal.new(1, coef, -places)
      shown = missing |> Decimal.to_string(:normal) |> shown_shortfall()

      assert Decimal.gte?(shown, missing)
    end
  end

  test "a shortfall is rounded up to the shown places" do
    assert Decimal.equal?(shown_shortfall("1234.567"), "1234.57")
    assert Decimal.equal?(shown_shortfall("0.0012341"), "0.00124")
    assert Decimal.equal?(shown_shortfall("5"), "5")
  end

  # The figure the line shows, as a number.
  defp shown_shortfall(missing) do
    html =
      render_component(&AuctionBook.return_line/1,
        id: "back",
        status: {:minimum, missing},
        unit: "USDC",
        usd_rate: nil,
        ends_at: nil
      )

    [_, figure] = Regex.run(~r/data-count>\s*([0-9,.]+)\s*</, html)
    figure |> String.replace(",", "") |> Decimal.new()
  end
end
