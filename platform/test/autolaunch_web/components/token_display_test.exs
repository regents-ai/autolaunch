defmodule AutolaunchWeb.TokenDisplayTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.TokenDisplay

  # A long Revstake price once carried every digit into its hover and
  # screen-reader text; both now carry the short figure shown on screen.
  test "a long price gives its short figure to the hover and screen-reader text" do
    html = render_component(&TokenDisplay.price/1, amount: "0.000000012345678901234567")

    assert html =~ ~s(title="0.00000001235")
    assert html =~ ~r/class="[^"]*visually-hidden[^"]*">\s*0.00000001235\s*</
    refute html =~ "12345678901234567"
  end

  # A bid's limit set far above any real price once filled the activity table
  # as 26590000000 SNDK; it is written as supply figures are, exact on hover.
  test "a price of a million or more is shortened with its exact amount kept" do
    html = render_component(&TokenDisplay.price/1, amount: "26590000000", unit: "SNDK")

    assert html =~ ~r/data-count>\s*26.59B\s*</
    assert html =~ ~s(title="26590000000 SNDK")
    assert html =~ ~r/class="[^"]*visually-hidden[^"]*">\s*26590000000 SNDK\s*</
  end

  # Exact pool prices carry up to 96 decimal places, past Decimal's default
  # parse limit; both sides of a million render.
  test "a price with a 96-place fraction renders on either side of a million" do
    fraction = String.duplicate("7", 96)

    small = render_component(&TokenDisplay.price/1, amount: "0.#{fraction}", unit: "SNDK")

    large =
      render_component(&TokenDisplay.price/1, amount: "26590000000.#{fraction}", unit: "SNDK")

    assert small =~ ~r/data-count>\s*0.7778\s*</
    assert large =~ ~r/data-count>\s*26.59B\s*</
  end
end
