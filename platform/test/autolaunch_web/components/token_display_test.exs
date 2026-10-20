defmodule AutolaunchWeb.TokenDisplayTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  # A positive amount as the chain gives it: up to 40 digits with up to 96
  # places after the point.
  defp chain_amount do
    gen all(
          digits <- integer(1..Integer.pow(10, 40)),
          places <- integer(0..96)
        ) do
      Decimal.new(1, digits, -places) |> Decimal.to_string(:normal)
    end
  end

  defp dec(text) do
    {decimal, ""} = Decimal.parse(text, max_digits: :infinity)
    decimal
  end

  defp significant(text) do
    text
    |> String.replace(".", "")
    |> String.trim_leading("0")
    |> String.trim_trailing("0")
    |> String.length()
  end

  # Refunds and claims say "1.234 USDC was returned to your wallet" from
  # short(amount, :down): never more than was returned, and within one step of
  # the fourth digit of it. The nearest form is within half a step.
  property "a short amount keeps four digits and never rounds a refund up" do
    check all(amount <- chain_amount(), max_runs: 1000) do
      exact = dec(amount)
      down = TokenDisplay.short(amount, :down)
      nearest = TokenDisplay.short(amount)
      # One unit of the fourth significant digit of the exact amount.
      step = Decimal.new(1, 1, length(Integer.digits(exact.coef)) + exact.exp - 4)

      assert significant(down) <= 4 and significant(nearest) <= 4
      assert Decimal.compare(dec(down), exact) != :gt
      assert Decimal.lt?(Decimal.sub(exact, dec(down)), step)

      half = Decimal.div(step, 2)
      off = exact |> Decimal.sub(dec(nearest)) |> Decimal.abs()
      assert Decimal.compare(off, half) != :gt
    end
  end

  # 0.0000000444 is written 0.0₇444. Writing the run back out gives the text
  # it came from, and no run of four zeros after a point is left to count.
  property "counted zeros write back to the same figure" do
    check all(
            amount <- chain_amount(),
            unit <- member_of(["", " USDC", " REGENT"]),
            max_runs: 1000
          ) do
      text = TokenDisplay.short(amount) <> unit
      counted = TokenDisplay.zeros(text)

      written_out =
        Regex.replace(~r/0\.0([₀-₉]+)/u, counted, fn _all, count ->
          zeros = count |> String.to_charlist() |> Enum.map(&(&1 - 0x2080)) |> Integer.undigits()
          "0." <> String.duplicate("0", zeros)
        end)

      assert written_out == text
      refute counted =~ ~r/(?<![\d.])0\.0000/
    end
  end
end
