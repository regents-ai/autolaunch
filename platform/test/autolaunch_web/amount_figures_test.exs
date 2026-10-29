defmodule AutolaunchWeb.AmountFiguresTest do
  @moduledoc """
  Figures the amounts review found wrong: a shortfall that read less than is
  missing, a typed budget with an exponent, a negative dollar figure and a
  Decimal's scientific hover text.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.Components.AuctionBook
  alias AutolaunchWeb.{TokenDisplay, UsdValue}

  defp shortfall(missing) do
    render_component(&AuctionBook.return_line/1,
      id: "back",
      status: {:minimum, missing},
      unit: "REGENT",
      usd_rate: nil,
      ends_at: nil
    )
  end

  test "SHORTFALL_NEVER_LESS: what is still needed is rounded up at its last shown place" do
    assert shortfall("1234.5678") =~ ~r/data-count>\s*1,234.57\s*</
    assert shortfall("0.9999") =~ ~r/data-count>\s*1.00\s*</
    assert shortfall("0.0009991") =~ ~r/data-count>\s*0.00100\s*</
    assert shortfall("1234.56") =~ ~r/data-count>\s*1,234.56\s*</
  end

  test "a typed budget with an exponent has no dollar figure, and the page still draws" do
    html = render_component(&UsdValue.usd/1, amount: "1e6144", rate: Decimal.new(200))

    refute html =~ "$"
    assert render_component(&UsdValue.usd/1, amount: ".5", rate: Decimal.new(2)) =~ "≈ $1.00"
  end

  test "a negative dollar figure puts its sign before the dollar mark" do
    assert render_component(&UsdValue.usd/1, amount: "-3", rate: Decimal.new(2)) =~ "≈ -$6.00"
    assert UsdValue.dollars(Decimal.new("-0")) == "$0"
  end

  test "a Decimal's hover and screen-reader text is plain, never scientific" do
    html = render_component(&TokenDisplay.amount/1, amount: Decimal.new("1.234E+4"), unit: "ETH")

    assert html =~ ~s(title="12340 ETH")
    refute html =~ "E+"
  end
end
