defmodule Autolaunch.CoveredCalls.TermsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.CoveredCalls.Terms
  alias AutolaunchWeb.CoveredCallsFormat, as: F

  @unit 100_000_000
  @day 86_400
  @week 7 * @day

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

  property "a listing's term is the days to its expiry, to the nearest day and never under one" do
    check all(now <- integer(1_700_000_000..2_100_000_000), ahead <- integer(1..(40 * @day))) do
      days = Terms.term_days(now + ahead, now)

      assert days >= 1
      assert abs(days * @day - ahead) <= div(@day, 2) or (days == 1 and ahead < @day)
    end
  end

  test "an exercise window's time left is whole hours from an hour up, minutes below, until it closes" do
    # The same cases as the browser's countdown (assets/test/countdown.test.ts).
    for {seconds, said} <- [
          {86_400, "Closes in 24 h"},
          {5 * 3_600 + 59 * 60, "Closes in 5 h"},
          {3_600, "Closes in 1 h"},
          {3_599, "Closes in 59 min"},
          {61, "Closes in 1 min"},
          {30, "Closes in 1 min"},
          {0, "Closed"},
          {-5, "Closed"}
        ],
        do: assert(F.closes_in(seconds) == said)
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

  # The bid figures against CoveredCallsV2's own test vectors
  # (contracts/covered-calls-v2/test/CoveredCallsV2.bids.t.sol): ten tokens at a
  # $3 premium, with tokens of 10^8 raw units and USDC of 10^6.
  @usd 1_000_000
  @ten_token_bid %{amount: 10 * @unit, filled: 0, premium_per_token: 3 * @usd}

  test "a bid escrows its whole premium and a raise adds the premium of the raised amount, as the contract counts them" do
    # test_bid_escrowsTheWholePremiumAndRecordsTerms, test_bid_escrowRoundsUpLikeAFill
    assert Terms.usdc_for(10 * @unit, 3 * @usd, @unit) == 30 * @usd
    assert Terms.usdc_for(1, 3 * @usd, @unit) == 1
    # test_raiseBid_addsAmountAndEscrowAtTheSameTerms
    assert Terms.raise_cost(@ten_token_bid, 5 * @unit, @unit) == 15 * @usd

    # test_raiseBid_dustRaisesAddUpToOneBid: 99 raises of one raw unit on a
    # one-unit bid escrow 3 micro-USDC in all, the premium of 100 units bid at once.
    {bid, escrowed} =
      Enum.reduce(1..99, {%{amount: 1, premium_per_token: 3 * @usd}, 1}, fn _raise,
                                                                            {bid, escrowed} ->
        {%{bid | amount: bid.amount + 1}, escrowed + Terms.raise_cost(bid, 1, @unit)}
      end)

    assert bid.amount == 100
    assert escrowed == Terms.usdc_for(100, 3 * @usd, @unit)
    assert escrowed == 3
  end

  test "a sale into a bid pays its slice of the bid's premium less its slice of the fee, as the contract counts them" do
    # test_sellToBid_locksStockPaysTheSellerAndGivesTheBidderTheCalls
    assert Terms.sale(@ten_token_bid, 4 * @unit, @unit) ==
             %{premium: 12 * @usd, fee: 120_000, receive: 12 * @usd - 120_000}

    # test_sellToBid_dustSalesShareTheRoundingAndNeverOverdrawTheEscrow: a
    # 100-unit bid escrows 3 micro-USDC; the first one-unit sale is paid 1 and
    # gives it all as the fee, the second is paid nothing, and once all 100 are
    # sold the sellers have 2 and staking 1.
    dust = %{amount: 100, filled: 0, premium_per_token: 3 * @usd}
    assert Terms.sale(dust, 1, @unit) == %{premium: 1, fee: 1, receive: 0}
    assert Terms.sale(%{dust | filled: 1}, 1, @unit) == %{premium: 0, fee: 0, receive: 0}

    sales =
      for {filled, amount} <- [{0, 1}, {1, 1}, {2, 98}],
          do: Terms.sale(%{dust | filled: filled}, amount, @unit)

    assert Enum.sum_by(sales, & &1.premium) == 3
    assert Enum.sum_by(sales, & &1.fee) == 1
    assert Enum.sum_by(sales, & &1.receive) == 2
  end

  test "cancelling a bid frees the escrow behind its unsold part, and a bid's minimum sale is a token or the whole bid" do
    # test_cancelBid_stopsSalesAndReleasesOnlyTheUnspentEscrow: 3 of 10 sold
    assert Terms.escrow_left(%{@ten_token_bid | filled: 3 * @unit}, @unit) == 21 * @usd
    # test_refundBid_aPartlySoldBidRefundsTheUnsoldEscrowAfterExpiry
    assert Terms.escrow_left(%{@ten_token_bid | filled: 3 * @unit + 7}, @unit) ==
             Terms.usdc_for(10 * @unit, 3 * @usd, @unit) -
               Terms.usdc_for(3 * @unit + 7, 3 * @usd, @unit)

    assert Terms.min_sale(10 * @unit, @unit) == @unit
    assert Terms.min_sale(@unit, @unit) == @unit
    assert Terms.min_sale(@unit - 1, @unit) == @unit - 1
  end

  property "however a bid is sold into or raised, the sales add up to one sale and the raises to one raise" do
    check all(
            amount <- integer(1..(1_000 * @unit)),
            premium <- integer(1..(10_000 * @usd)),
            cuts <- list_of(integer(1..(1_000 * @unit)), max_length: 6)
          ) do
      bid = %{amount: amount, filled: 0, premium_per_token: premium}
      parts = split(amount, cuts)

      {sales, _sold} =
        Enum.map_reduce(parts, bid, fn part, bid ->
          {Terms.sale(bid, part, @unit), %{bid | filled: bid.filled + part}}
        end)

      whole = Terms.sale(bid, amount, @unit)
      assert Enum.sum_by(sales, & &1.premium) == whole.premium
      assert Enum.sum_by(sales, & &1.fee) == whole.fee
      assert whole.premium == Terms.usdc_for(amount, premium, @unit)
      assert whole.fee == Terms.fee(whole.premium)
      assert Enum.all?(sales, &(&1.receive >= 0 and &1.fee <= &1.premium))

      {raised, escrowed} =
        Enum.reduce(parts, {%{amount: 0, premium_per_token: premium}, 0}, fn part,
                                                                             {bid, escrowed} ->
          {%{bid | amount: bid.amount + part}, escrowed + Terms.raise_cost(bid, part, @unit)}
        end)

      assert raised.amount == amount
      assert escrowed == Terms.usdc_for(amount, premium, @unit)
    end
  end

  property "another sale landing first moves a sale's premium by at most one micro-USDC, never below the exact premium" do
    # testFuzz_flow_anotherSaleFirstMovesThePriceByAtMostOneMicro
    check all(
            premium <- integer(1..(10_000 * @usd)),
            amount <- integer(1..(25 * @unit)),
            first <- integer(1..(25 * @unit))
          ) do
      bid = %{amount: 50 * @unit, filled: 0, premium_per_token: premium}
      quoted = Terms.sale(bid, amount, @unit).premium
      paid = Terms.sale(%{bid | filled: first}, amount, @unit).premium
      exact = div(amount * premium, @unit)

      assert paid <= quoted + 1 and paid + 1 >= quoted
      assert paid >= exact and paid <= exact + 1
    end
  end

  test "a bid is open until its expiry while some is unsold, then sold, cancelled or expired" do
    bid = %{expiry: 1_000, amount: 10, filled: 4}
    assert Terms.bid_stage(bid, 999) == :open
    assert Terms.bid_stage(bid, 1_000) == :expired
    assert Terms.bid_stage(%{bid | filled: 10}, 999) == :sold
    assert Terms.bid_stage(%{bid | filled: 10}, 1_000) == :sold
    # cancelBid lowers the amount to what was sold: nothing sold reads as cancelled.
    assert Terms.bid_stage(%{bid | amount: 0, filled: 0}, 999) == :cancelled
    assert Terms.bid_stage(%{bid | amount: 4}, 999) == :sold
  end

  # `amount` cut into parts at the given points, each part at least one unit.
  defp split(amount, cuts) do
    points = cuts |> Enum.map(&rem(&1, amount)) |> Enum.reject(&(&1 == 0)) |> Enum.uniq()
    edges = Enum.sort([0, amount | points])
    edges |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
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
