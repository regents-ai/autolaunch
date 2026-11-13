defmodule Autolaunch.Stocks.AmountsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Stocks.Amounts

  @uint256_max Integer.pow(2, 256) - 1

  test "raw uint256 quantities roundtrip without float loss" do
    max = @uint256_max

    for decimals <- [0, 6, 8, 18, 255], raw <- [0, 1, 9_007_199_254_740_993, max] do
      text = Rpc.format_units(raw, decimals)
      assert {:ok, ^raw} = Amounts.parse_units(text, decimals)
    end

    assert {:error, :amount_not_representable} =
             Amounts.parse_units(Integer.to_string(max + 1), 0)
  end

  # The figure a wallet review shows reads back as the exact raw amount the
  # chain holds, from one unit to the largest uint256, at 0 to 36 decimals.
  property "a shown amount reads back as the exact raw amount" do
    check all(
            digits <- integer(1..78),
            seed <- integer(0..@uint256_max),
            decimals <- integer(0..36)
          ) do
      raw = rem(seed, Integer.pow(10, digits))
      text = Rpc.format_units(raw, decimals)

      assert {:ok, ^raw} = Amounts.parse_units(text, decimals)
      refute text =~ ~r/\.\d*0\z/
    end
  end

  test "the largest uint256 amounts are shown digit for digit" do
    assert Rpc.format_units(@uint256_max, 18) ==
             "115792089237316195423570985008687907853269984665640564039457.584007913129639935"

    assert Rpc.format_units(@uint256_max, 0) == Integer.to_string(@uint256_max)
    assert Rpc.format_units(1_500_000, 6) == "1.5"
    assert Rpc.format_units(5, 6) == "0.000005"
    assert Rpc.format_units(0, 6) == "0"
  end

  test "amount precision is never silently discarded" do
    assert {:ok, 123_456_789} = Amounts.parse_units("1.23456789", 8)
    assert {:ok, 100_000_000} = Amounts.parse_units("1.000000000", 8)
    assert {:error, :amount_not_representable} = Amounts.parse_units("1.000000001", 8)
    assert {:ok, 10_000_000} = Amounts.parse_units(".1", 8)

    for value <- [1.0, 1, true, nil, "1e8", " 1", "1\n", "-1", "1.", "."] do
      assert {:error, :invalid_decimal} = Amounts.parse_units(value, 8)
    end
  end

  test "CCA candidates preserve dimensions and never exceed the entered price" do
    q96 = Integer.pow(2, 96)

    for stock_decimals <- [6, 8, 18], new_decimals <- [6, 8, 18] do
      assert {:ok, result} = Amounts.cca_price("1.25", stock_decimals, new_decimals)
      numerator = 125 * Integer.pow(10, stock_decimals) * q96
      denominator = 100 * Integer.pow(10, new_decimals)
      assert result.candidate_price_q96 * denominator <= numerator
      assert (result.candidate_price_q96 + 1) * denominator > numerator
      assert result.rounding_remainder == rem(numerator, denominator)
      assert result.adjustment_required == (rem(numerator, denominator) != 0)
    end

    assert {:error, :price_out_of_range} = Amounts.cca_price("0", 8, 18)

    assert {:error, :price_out_of_range} =
             Amounts.cca_price("0.00000000000000000000000000000000000001", 8, 18)
  end
end
