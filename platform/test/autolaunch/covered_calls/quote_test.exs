defmodule Autolaunch.CoveredCalls.QuoteTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.CoveredCalls.{Quote, Terms}

  @now 1_793_491_595
  @steps [10_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_500_000, 5_000_000] ++
           [10_000_000, 25_000_000]

  defp book(answer, updated_at),
    do: %{
      market: %{symbol: "AMZNc"},
      now: @now,
      price: %{answer: answer, decimals: 8, updated_at: updated_at}
    }

  property "three strikes on the step, rising, each above the price, at every price from a cent" do
    check all(price <- one_of([integer(1..1_000_000), integer(1..100_000_000_000)])) do
      step = Quote.step(price)
      strikes = Quote.strikes(price)

      assert step in @steps
      assert step == 10_000 or step * 100 <= price
      assert length(strikes) == 3
      assert strikes == Enum.sort(Enum.uniq(strikes))
      assert Enum.all?(strikes, &(rem(&1, step) == 0 and &1 > price))
      # Each sits at its target or, for a price under a dollar, one step above the one before.
      for {strike, bps} <- Enum.zip(strikes, [100, 300, 500]),
          do: assert(strike * 10_000 >= price * (10_000 + bps))
    end
  end

  test "the worked set from the strike design: AMZNc at $240.27" do
    {:ok, set} = Quote.set(book(24_027_125_000, 1_793_390_057))

    assert set.price_per_token == 240_271_250
    assert set.strike_step == 1_000_000
    assert set.price_fresh
    assert Enum.map(set.windows, & &1.expiry) == Terms.expiries(@now)

    assert Enum.map(set.windows, fn window ->
             Enum.map(window.strikes, &{&1.strike_per_token, &1.suggested_premium_per_token})
           end) == [
             [{243_000_000, 2_750_000}, {248_000_000, 1_270_000}, {253_000_000, 510_000}],
             [{243_000_000, 4_380_000}, {248_000_000, 2_650_000}, {253_000_000, 1_490_000}],
             [{243_000_000, 5_630_000}, {248_000_000, 3_790_000}, {253_000_000, 2_440_000}],
             [{243_000_000, 6_700_000}, {248_000_000, 4_790_000}, {253_000_000, 3_320_000}]
           ]

    assert Enum.map(hd(set.windows).strikes, & &1.above_bps) == [114, 322, 530]
    assert Enum.map(hd(set.windows).strikes, & &1.fee_per_token) == [27_500, 12_700, 5_100]
  end

  test "under a dollar the strikes stay a cent apart: $0.30 gives $0.31, $0.32 and $0.33" do
    assert Quote.strikes(300_000) == [310_000, 320_000, 330_000]
  end

  test "a price more than four days old keeps the strikes and suggests no premium" do
    {:ok, set} = Quote.set(book(24_027_125_000, @now - 4 * 86_400 - 1))

    refute set.price_fresh

    for window <- set.windows do
      assert Enum.map(window.strikes, & &1.strike_per_token) ==
               [243_000_000, 248_000_000, 253_000_000]

      assert Enum.all?(window.strikes, &(&1.suggested_premium_per_token == nil))
      assert Enum.all?(window.strikes, &(&1.fee_per_token == nil))
    end
  end

  test "no strikes without an answer from the feed" do
    assert Quote.set(%{market: %{symbol: "AMZNc"}, now: @now, price: nil}) ==
             {:error, :price_unavailable}
  end
end
