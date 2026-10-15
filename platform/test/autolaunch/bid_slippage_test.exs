defmodule Autolaunch.BidSlippageTest do
  use ExUnit.Case, async: true

  alias Autolaunch.BidSlippage

  test "the signed minimum never permits more loss than the chosen percentage, even at uint128 precision" do
    assert {:ok, 500} = BidSlippage.parse(BidSlippage.default())
    assert {:ok, 1_250} = BidSlippage.parse("12.50")
    assert BidSlippage.percent(1_250) == "12.5"
    assert BidSlippage.minimum(100_000, 500) == 95_000
    assert BidSlippage.minimum(100_000, 1_250) == 87_500

    for quote <- [1, 101, Integer.pow(2, 128) - 1], bps <- [0, 1, 500, 1_250, 9_999] do
      minimum = BidSlippage.minimum(quote, bps)
      assert minimum > 0
      assert minimum * 10_000 >= quote * (10_000 - bps)
      assert (minimum - 1) * 10_000 < quote * (10_000 - bps)
    end

    for invalid <- [nil, 5, "", "-1", "100", "1e1", "NaN", "5.001", "5%"] do
      assert {:error, :invalid_slippage} = BidSlippage.parse(invalid)
    end
  end
end
