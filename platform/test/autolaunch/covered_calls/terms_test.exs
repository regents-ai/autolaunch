defmodule Autolaunch.CoveredCalls.TermsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.CoveredCalls.Terms
  alias AutolaunchWeb.CoveredCallsFormat, as: F

  @unit 100_000_000
  @week 7 * 86_400

  property "a fill or an exercise pays the exact amount rounded up, as the contract does" do
    check all(amount <- integer(1..(1_000 * @unit)), per_token <- integer(1..10_000_000_000)) do
      paid = Terms.usdc_for(amount, per_token, @unit)
      assert paid * @unit >= amount * per_token
      assert paid * @unit < amount * per_token + @unit
      # Splitting a payment never pays less than paying it whole.
      half = div(amount, 2)

      if half > 0,
        do:
          assert(
            Terms.usdc_for(half, per_token, @unit) +
              Terms.usdc_for(amount - half, per_token, @unit) >= paid
          )
    end
  end

  property "the fee is 1% of the premium rounded up, never more than the premium" do
    check all(premium <- integer(1..1_000_000_000_000)) do
      fee = Terms.fee(premium)
      assert fee * 100 >= premium
      assert fee * 100 < premium + 100
      assert fee <= premium
    end
  end

  property "every expiry offered is a future Friday at 21:00 UTC, a week apart" do
    check all(now <- integer(1_700_000_000..2_100_000_000)) do
      expiries = Terms.expiries(now)
      assert length(expiries) == 4
      assert Enum.all?(expiries, &(Terms.weekly?(&1) and &1 > now))
      assert hd(expiries) - now <= @week

      assert expiries
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> b - a == @week end)

      for expiry <- expiries do
        at = DateTime.from_unix!(expiry)
        assert Date.day_of_week(at) == 5
        assert {at.hour, at.minute, at.second} == {21, 0, 0}
      end
    end
  end

  test "an hour either side of Friday 21:00 UTC is not an expiry" do
    [expiry | _] = Terms.expiries(1_800_000_000)
    refute Terms.weekly?(expiry - 3_600)
    refute Terms.weekly?(expiry + 3_600)
  end

  test "a listing moves from open to the exercise window to closed" do
    listing = %{expiry: 1_000, amount: 10, filled: 4}
    assert Terms.stage(listing, 999) == :open
    assert Terms.stage(%{listing | filled: 10}, 999) == :sold
    assert Terms.stage(listing, 1_000) == :exercise
    assert Terms.stage(listing, 1_000 + 86_399) == :exercise
    assert Terms.stage(listing, 1_000 + 86_400) == :closed
  end

  property "typed token and dollar amounts are read exactly, and shown back as typed" do
    check all(
            whole <- integer(0..100_000),
            fraction <- integer(0..99_999_999),
            whole + fraction > 0
          ) do
      text = "#{whole}." <> String.pad_leading(Integer.to_string(fraction), 8, "0")
      raw = F.parse_tokens(text, @unit)
      assert raw == whole * @unit + fraction
      assert Decimal.equal?(Decimal.new(F.tokens(raw, @unit)), Decimal.new(text))
    end
  end

  test "an amount with more decimals than the token has, zero or text is not an amount" do
    assert F.parse_tokens("1.000000001", @unit) == nil
    assert F.parse_tokens("0", @unit) == nil
    assert F.parse_usd("ten") == nil
    assert F.parse_usd("$1,250.50") == 1_250_500_000
  end
end
