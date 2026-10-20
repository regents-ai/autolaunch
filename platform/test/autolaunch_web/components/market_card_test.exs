defmodule AutolaunchWeb.MarketCardTest do
  @moduledoc """
  List figures (prices, volumes, market caps) are shortened to three
  significant digits with K, M, B or T. Whatever the amount, from a
  millionth of a cent to trillions, the short figure reads back within half
  a percent of it, never shows more than three digits, and never shows a
  thousand of one unit where the next unit fits ("1000K").
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AutolaunchWeb.Components.MarketCard

  @units %{
    "" => 1,
    "K" => 1_000,
    "M" => 1_000_000,
    "B" => 1_000_000_000,
    "T" => 1_000_000_000_000
  }

  # A positive amount with up to twelve digits, scaled from 10^-18 to 10^13,
  # so it lands on every unit; half the time it sits just under a power of
  # ten (999.5 to 999.9999), where rounding up reaches the next unit.
  defp amount do
    any = gen(all(digits <- integer(1..999_999_999_999), do: digits))
    near_next = gen(all(digits <- integer(9_995_000..9_999_999), do: digits))

    gen all(digits <- one_of([any, near_next]), exponent <- integer(-18..13)) do
      Decimal.new(1, digits, exponent)
    end
  end

  property "a short figure reads back within half a percent, in at most three digits" do
    check all(value <- amount(), max_runs: 2000) do
      shown = MarketCard.compact(value)
      assert [_, number, unit] = Regex.run(~r/^(\d+(?:\.\d+)?)([KMBT]?)$/, shown)

      back = Decimal.mult(Decimal.new(number), @units[unit])
      off = value |> Decimal.sub(back) |> Decimal.abs() |> Decimal.div(value)
      assert Decimal.compare(off, Decimal.new("0.005")) != :gt

      significant =
        number |> String.replace(".", "") |> String.trim_leading("0") |> String.trim_trailing("0")

      assert String.length(significant) <= 3
      if unit not in ["", "T"], do: assert(Decimal.lt?(Decimal.new(number), 1000))
    end
  end
end
