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
    assert F.parse_usd("$1250.50") == 1_250_500_000
  end

  test "a page reads again at the next expiry, window close or multiplier change, at most a week out" do
    assert Terms.next_wait([], 100) == nil
    assert Terms.next_wait([50, 100], 100) == nil
    assert Terms.next_wait([0, 400, 160], 100) == 60
    assert Terms.next_wait([100 + 30 * 86_400], 100) == @week
  end

  test "a comma, an exponent or an amount no contract call can carry is not an amount" do
    # "1,2" is $1.20 in much of the world and $12 in the US; neither is guessed.
    for text <- ["1,2", "1,250.50", "1.050,00", "0,5", "1e3", "-1", "1..2", ""],
        do: assert(F.parse_usd(text) == nil, text)

    assert F.parse_tokens("$5", @unit) == nil
    assert F.parse_usd(" $5 ") == 5_000_000
    assert F.parse_usd("250.01") == 250_010_000
    assert F.parse_usd("250.005") == nil
    assert F.parse_tokens(Integer.to_string(2 ** 128), 1) == nil
    assert F.parse_tokens(Integer.to_string(2 ** 128 - 1), 1) == 2 ** 128 - 1
  end

  property "a dollar amount a person pays is shown rounded up to the cent, never below it" do
    check all(micro <- integer(1..1_000_000_000_000_000)) do
      shown =
        F.usd_due(micro) |> String.trim_leading("$") |> String.replace(",", "") |> Decimal.new()

      exact = Decimal.div(Decimal.new(micro), 1_000_000)
      assert Decimal.compare(shown, exact) != :lt
      assert Decimal.compare(Decimal.sub(shown, exact), Decimal.new("0.01")) == :lt
    end
  end

  property "a dollar figure on a page is cut, never rounded up, and never more than 1% short" do
    check all(micro <- integer(1..1_000_000_000_000_000)) do
      shown = F.usd(micro) |> String.trim_leading("$") |> String.replace(",", "") |> Decimal.new()
      exact = Decimal.div(Decimal.new(micro), 1_000_000)
      assert Decimal.compare(shown, exact) != :gt
      assert Decimal.compare(Decimal.mult(shown, 100), Decimal.mult(exact, 99)) != :lt
    end
  end
end
