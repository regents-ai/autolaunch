defmodule AutolaunchWeb.TokenDisplayTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.TokenDisplay

  # A long Revstake price once carried every digit into its hover and
  # screen-reader text; both carry only the figure shown on screen.
  test "a long price gives no more than its shown figure to hover and screen readers" do
    html = render_component(&TokenDisplay.price/1, amount: "0.000000012345678901234567")

    assert html =~ ~r/data-count>\s*0.0000000123\s*</
    refute html =~ "12345678901234567"
  end

  # Exact pool prices carry up to 96 decimal places, past Decimal's default
  # parse limit; both sides of 1 render.
  test "a price with a 96-place fraction renders on either side of 1" do
    fraction = String.duplicate("7", 96)

    small = render_component(&TokenDisplay.price/1, amount: "0.#{fraction}", unit: "SNDK")

    large =
      render_component(&TokenDisplay.price/1, amount: "26590000000.#{fraction}", unit: "SNDK")

    assert small =~ ~r/data-count>\s*0.777\s*</
    assert large =~ ~r/data-count>\s*26,590,000,000.77\s*</
  end
end
