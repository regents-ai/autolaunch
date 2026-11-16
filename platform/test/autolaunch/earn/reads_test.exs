defmodule Autolaunch.Earn.ReadsTest do
  @moduledoc """
  What Earn reads from the pool's reserve word by word: the configuration
  bitmap's decimals, flags and supply cap, beside fields Earn does not read,
  the liquidity rate as a yearly percentage, the market token, and the
  treasury's share; and an amount typed, read and written back unchanged.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.Earn.{Amount, Answer, Chain}

  @ray 10 ** 27

  # A reserve's fifteen words with this configuration, rate, market token and treasury share.
  defp reserve(config, rate \\ 0, a_token \\ 0xABC, accrued \\ 0),
    do: [config, @ray, rate, 0, 0, 0, 0, 0, a_token, 0, 0, 0, accrued, 0, 0]

  defp bits(value, at), do: Bitwise.bsl(value, at)

  test "the configuration bitmap gives decimals, the three flags and the supply cap, and nothing else" do
    # Every field Earn does not read set to all ones: loan to value, liquidation
    # threshold and bonus, borrowing, flash loans, borrow cap and the rest.
    noise =
      Enum.reduce([0..47, [58, 59, 61, 62, 63], 64..115, 152..255], 0, fn range, word ->
        Enum.reduce(range, word, &Bitwise.bor(&2, bits(1, &1)))
      end)

    decoded = Chain.decode(reserve(noise + bits(6, 48) + bits(1, 56) + bits(1_000_000_000, 116)))

    assert Map.take(decoded, [:decimals, :active, :frozen, :paused, :cap]) ==
             %{decimals: 6, active: true, frozen: false, paused: false, cap: 1_000_000_000}

    assert %{active: false, frozen: true, paused: true} =
             Chain.decode(reserve(noise + bits(1, 57) + bits(1, 60)))

    # The largest cap the 36 bits hold.
    assert %{cap: 68_719_476_735} = Chain.decode(reserve(bits(2 ** 36 - 1, 116)))
  end

  test "the rate, market token and treasury share come from their own words" do
    decoded =
      Chain.decode(
        reserve(0, div(468 * @ray, 10_000), 0x4E65FE4DBA92790696D040AC24AA414708F5C0AB, 77)
      )

    assert decoded.rate == div(468 * @ray, 10_000)
    assert decoded.a_token == "0x4e65fe4dba92790696d040ac24aa414708f5c0ab"
    assert decoded.accrued_to_treasury == 77
    assert Chain.decode(reserve(0, 0, 1)).a_token == "0x0000000000000000000000000000000000000001"
  end

  test "the rate shows as a yearly percentage to two places, rounded half up" do
    assert Answer.yearly_percent(0) == "0.00"
    assert Answer.yearly_percent(div(468 * @ray, 10_000)) == "4.68"
    assert Answer.yearly_percent(div(5 * @ray, 100_000)) == "0.01"
    assert Answer.yearly_percent(div(5 * @ray, 100_000) - 1) == "0.00"
    assert Answer.yearly_percent(div(12_345 * @ray, 10_000)) == "123.45"
  end

  test "an amount reads into one of three states" do
    assert Amount.entry("", 6) == :empty
    assert Amount.entry("   ", 6) == :empty
    assert Amount.entry(nil, 6) == :empty
    assert Amount.entry("1.5", 6) == {:valid, 1_500_000}
    assert Amount.entry(".5", 6) == {:valid, 500_000}
    assert Amount.entry("2.", 6) == {:valid, 2_000_000}
    assert Amount.entry("0.000001", 6) == {:valid, 1}
    assert Amount.entry("0", 6) == {:invalid, :zero}
    assert Amount.entry("0.000000", 6) == {:invalid, :zero}
    assert Amount.entry("0.0000001", 6) == {:invalid, :too_precise}
    assert Amount.entry(".", 6) == {:invalid, :not_a_number}
    assert Amount.entry("1,000", 6) == {:invalid, :not_a_number}
    assert Amount.entry("-1", 6) == {:invalid, :not_a_number}
    assert Amount.entry("1e3", 6) == {:invalid, :not_a_number}
    assert Amount.entry(Integer.to_string(2 ** 128), 0) == {:invalid, :too_large}
    assert Amount.entry(Integer.to_string(2 ** 128 - 1), 0) == {:valid, 2 ** 128 - 1}
  end

  property "units written as text read back as exactly the same units" do
    check all(
            decimals <- integer(0..18),
            units <- one_of([integer(1..1_000_000), integer(1..(2 ** 128 - 1))])
          ) do
      text = Amount.text(units, decimals)
      assert text =~ ~r/\A\d+(\.\d*[1-9])?\z/
      assert Amount.entry(text, decimals) == {:valid, units}
    end
  end

  property "text that reads as an amount writes back as the same amount" do
    check all(
            decimals <- integer(0..18),
            whole <- string(?0..?9, min_length: 1, max_length: 12),
            fraction <- string(?0..?9, max_length: decimals),
            dot? <- boolean()
          ) do
      typed = if dot?, do: whole <> "." <> fraction, else: whole

      case Amount.entry(typed, decimals) do
        {:valid, units} ->
          assert Amount.entry(Amount.text(units, decimals), decimals) == {:valid, units}

        {:invalid, :zero} ->
          assert String.replace(typed, ~r/[0.]/, "") == ""
      end
    end
  end
end
