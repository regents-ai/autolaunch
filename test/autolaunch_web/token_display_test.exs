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
end
