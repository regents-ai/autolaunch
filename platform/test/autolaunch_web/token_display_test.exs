defmodule AutolaunchWeb.TokenDisplayTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.TokenDisplay

  defp amount(assigns), do: render_component(&TokenDisplay.amount/1, assigns)

  # An ordinary wallet figure is already readable, so it is rendered once, as
  # itself. Nothing is hidden, shortened or duplicated for a screen reader.
  test "ORDINARY_AMOUNTS_ARE_RENDERED_EXACTLY_ONCE" do
    for {value, unit, expected} <- [
          {"10", "REGENT", "10 REGENT"},
          {"4.25", "USDC", "4.25 USDC"},
          {"0.000000000000000001", "REGENT", "0.000000000000000001 REGENT"},
          {"999999.5", "REGENT", "999999.5 REGENT"}
        ] do
      html = amount(%{amount: value, unit: unit})

      assert String.trim(html) == expected
    end
  end

  # A production-sized figure is shortened for width, and the exact figure stays
  # in the page as real text rather than as an attribute on a generic element.
  test "COMPACT_DISPLAY_KEEPS_THE_EXACT_FIGURE_READABLE" do
    html = amount(%{amount: "7390000000", unit: "REGENT"})

    assert html =~ ~s(<span aria-hidden="true" title="7390000000 REGENT">7.39B REGENT</span>)
    assert html =~ ~s(<span class="visually-hidden">7390000000 REGENT</span>)
  end

  # Display is allowed to say less than the position, never more: the mantissa is
  # truncated, so a figure a hair under a boundary never reads as the boundary.
  test "COMPACTION_TRUNCATES_AND_NEVER_ROUNDS_A_BALANCE_UP" do
    for {value, expected} <- [
          {"7389999999.9", "7.38B"},
          {"999999999.999999999999999999", "999.99M"},
          {"1000000", "1M"},
          {"7390000000.123456789012345678", "7.39B"}
        ] do
      assert amount(%{amount: value, unit: "REGENT"}) =~ ">#{expected} REGENT</span>"
    end
  end

  # A figure Base could not be read for is not a zero and not a blank.
  test "AN_UNREAD_AMOUNT_RENDERS_THE_DASH" do
    assert amount(%{amount: nil, unit: "REGENT"}) |> String.trim() == "—"
  end

  defp price(assigns), do: render_component(&TokenDisplay.price/1, assigns)

  # A price with four or fewer significant digits is already readable and is
  # rendered once, as itself.
  test "SHORT_PRICES_ARE_RENDERED_EXACTLY_ONCE" do
    for {value, unit, expected} <- [
          {"0.001", "REGENT", "0.001 REGENT"},
          {"1250", "REGENT", "1250 REGENT"},
          {"0", "REGENT", "0 REGENT"},
          {"0.5", nil, "0.5"}
        ] do
      assert price(%{amount: value, unit: unit}) |> String.trim() == expected
    end
  end

  # An exact Q96 price keeps every one of its digits in the page while the
  # screen shows four significant ones, truncated so a price a hair under a
  # boundary never reads as the boundary.
  test "LONG_PRICES_ARE_TRUNCATED_TO_FOUR_SIGNIFICANT_DIGITS_WITH_THE_EXACT_FIGURE_KEPT" do
    exact =
      "0.0009999999999999999999999993646703595967223962047236950068107574907116941176354885101318359375"

    html = price(%{amount: exact, unit: "REGENT"})

    assert html =~ ~s(<span aria-hidden="true" title="#{exact} REGENT">0.0009999 REGENT</span>)
    assert html =~ ~s(<span class="visually-hidden">#{exact} REGENT</span>)

    for {value, expected} <- [
          {"123456.789", "123400"},
          {"0.00012345", "0.0001234"},
          {"99999", "99990"},
          {"-0.00012345", "-0.0001234"}
        ] do
      assert price(%{amount: value, unit: "REGENT"}) =~ ">#{expected} REGENT</span>"
    end
  end

  # Only presentation is shortened: an amount that is not a plain decimal, and
  # a missing one, are shown as they are.
  test "A_PRICE_THAT_IS_NOT_A_PLAIN_DECIMAL_OR_IS_MISSING_IS_SHOWN_AS_WRITTEN" do
    for written <- ["about 0.001", "NaN", "Infinity", "-Infinity", "1e5", "1.5E-3", "01.5", ".5", "1."] do
      assert price(%{amount: written, unit: "REGENT"}) |> String.trim() == "#{written} REGENT"
    end

    assert price(%{amount: nil, unit: "REGENT"}) |> String.trim() == "No price yet"

    assert price(%{amount: "", unit: nil, fallback: "Raise target pending"}) |> String.trim() ==
             "Raise target pending"
  end
end
