defmodule Autolaunch.CoveredCalls.QuoteTest do
  @moduledoc """
  A seller's quote through the operation the page, the HTTP route and the
  agent tool all call, on the covered-call chain double: every USDC figure a
  listing pays is the contract's own count and matches the steps prepared for
  the same listing, the three suggested strikes sit above the reference price
  on the stock's price step, and each expiry carries its exercise window.
  """

  use AutolaunchWeb.ConnCase, async: false
  use ExUnitProperties

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.{CoveredCalls, CoveredCallsChain}
  alias Autolaunch.CoveredCalls.Terms

  @unit CoveredCallsChain.unit()
  @now CoveredCallsChain.now()
  @expiry hd(Terms.expiries(@now))
  @cent 10_000
  @window 86_400

  setup do
    CoveredCallsChain.install()
  end

  defp ask(request),
    do:
      CoveredCalls.covered_call_quote("AMZNc", Map.put_new(request, :expiry, @expiry), actor: nil)

  defp refusal(request) do
    assert {:error, error} = ask(request)
    CoveredCalls.reason(error)
  end

  # The price step a strike is rounded to, said another way than the code
  # says it: the largest power of ten at most a hundredth of the price, and
  # never under a cent.
  defp step(spot), do: Enum.max([@cent | for(e <- 4..30, 10 ** e * 100 <= spot, do: 10 ** e)])

  property "every USDC figure a listing pays is what the contract counts for it" do
    check all(
            amount <- integer(1..(10_000 * @unit)),
            strike <- integer(1..10_000_000_000),
            premium <- integer(1..1_000_000_000)
          ) do
      assert {:ok, answer} =
               ask(%{amount: amount, strike_per_token: strike, premium_per_token: premium})

      %{receipt: receipt} = answer
      paid = Terms.usdc_for(amount, premium, @unit)

      assert {answer.amount, answer.strike_per_token, answer.premium_per_token} ==
               {amount, strike, premium}

      assert receipt.premium == paid
      assert receipt.fee == Terms.fee(paid)
      assert receipt.net_premium == paid - Terms.fee(paid)
      assert receipt.strike == Terms.usdc_for(amount, strike, @unit)
      assert receipt.reference_value == Terms.usdc_for(amount, answer.spot_per_token, @unit)
      assert receipt.net_premium_yield == receipt.net_premium / receipt.reference_value
    end
  end

  property "the three suggested strikes are ascending, above the reference price and on its price step" do
    check all(
            spot <- one_of([integer(1..999_999), integer(1_000_000..10_000_000_000_000)]),
            dust <- integer(0..99),
            amount <- integer(1..(1_000 * @unit))
          ) do
      CoveredCallsChain.put(%{price: spot * 100 + dust})
      assert {:ok, answer} = ask(%{amount: amount})
      assert answer.spot_per_token == spot

      strikes = Enum.map(answer.presets, & &1.strike_per_token)
      premiums = Enum.map(answer.presets, & &1.suggested_premium_per_token)
      assert length(strikes) == 3
      assert strikes == Enum.sort(Enum.uniq(strikes))
      assert Enum.all?(strikes, &(&1 > spot and rem(&1, step(spot)) == 0))
      # A higher strike is never worth more, and every suggestion is whole cents.
      assert premiums == Enum.sort(premiums, :desc)
      assert Enum.all?(premiums, &(&1 >= @cent and rem(&1, @cent) == 0))

      for preset <- answer.presets do
        assert preset.above_reference == (preset.strike_per_token - spot) / spot
        assert preset.premium == Terms.usdc_for(amount, preset.suggested_premium_per_token, @unit)
      end

      # From a dollar up, each is its percent above the reference price, at most a step more.
      if spot >= 1_000_000 do
        for {preset, percent} <- Enum.zip(answer.presets, [2, 5, 10]) do
          assert preset.strike_per_token * 100 >= spot * (100 + percent)
          assert preset.strike_per_token * 100 < spot * (100 + percent) + step(spot) * 100
        end
      end
    end
  end

  test "a $254 stock's strikes are whole dollars, and the quote prices the middle one with its suggestion" do
    assert {:ok, answer} = ask(%{amount: 10 * @unit})

    assert answer.spot_per_token == 254_000_000

    assert Enum.map(answer.presets, & &1.strike_per_token) == [
             260_000_000,
             267_000_000,
             280_000_000
           ]

    [_near, middle, _far] = answer.presets
    assert answer.strike_per_token == middle.strike_per_token
    assert answer.premium_per_token == answer.suggested_premium_per_token
    assert answer.suggested_premium_per_token == middle.suggested_premium_per_token
    assert answer.receipt.premium == 10 * answer.premium_per_token
    assert answer.receipt.reference_value == 2_540_000_000
  end

  test "without an amount the per-token figures come back and the totals are left empty" do
    assert {:ok, answer} = ask(%{strike_per_token: 270_000_000})

    assert answer.amount == nil and answer.receipt == nil
    assert Enum.all?(answer.presets, &(&1.premium == nil and &1.suggested_premium_per_token > 0))
    assert answer.strike_per_token == 270_000_000
    assert answer.suggested_premium_per_token > 0
  end

  test "each expiry offered is a weekly one with its 24-hour exercise window" do
    later = Enum.at(Terms.expiries(@now), 2)
    assert {:ok, answer} = ask(%{expiry: later})

    assert Enum.map(answer.expiries, & &1.expiry) == Terms.expiries(@now)

    for window <- answer.expiries do
      assert window.exercise_opens_at == window.expiry
      assert window.exercise_closes_at == window.expiry + @window
    end

    assert {answer.expiry, answer.exercise_closes_at} == {later, later + @window}
  end

  test "the term is the days to the chosen expiry: early Sunday to Friday evening is six" do
    # The chain double's latest block is Sunday 03:48 UTC; its next expiry is
    # Friday 21:00 UTC, 5 days 17 hours later.
    assert DateTime.from_unix!(@now) |> Date.day_of_week() == 7

    for {expiry, weeks} <- Enum.with_index(Terms.expiries(@now)) do
      assert {:ok, %{term_days: days}} = ask(%{expiry: expiry})
      assert days == 6 + 7 * weeks
    end
  end

  test "an expiry that is not a Friday close or past the four offered, one already passed, a stale price and a zero amount are refused" do
    assert refusal(%{expiry: @expiry + 3_600}) == :expiry_not_offered
    assert refusal(%{expiry: Enum.at(Terms.expiries(@now, 5), 4)}) == :expiry_not_offered
    assert refusal(%{expiry: @expiry - 7 * 86_400}) == :expiry_passed
    assert {:error, %Ash.Error.Invalid{}} = ask(%{amount: 0})

    assert {:error, %Ash.Error.Invalid{}} =
             CoveredCalls.covered_call_quote("AMZNc", %{}, actor: nil)

    CoveredCallsChain.put(%{price: 0})
    assert refusal(%{}) == :price_unavailable
  end

  describe "the steps prepared for the quoted listing" do
    setup :bidder

    test "list the quoted terms and charge a buyer exactly the receipt's premium, fee and strike",
         context do
      amount = 3 * @unit + 7
      assert {:ok, answer} = ask(%{amount: amount})

      assert {:ok, listed} =
               CoveredCalls.prepare_covered_call(
                 "AMZNc",
                 :list,
                 %{
                   signer: context.wallet,
                   amount: amount,
                   strike_per_token: answer.strike_per_token,
                   premium_per_token: answer.premium_per_token,
                   expiry: answer.expiry
                 },
                 actor: context.actor
               )

      assert listed.facts ==
               Map.take(answer, [:amount, :strike_per_token, :premium_per_token, :expiry])

      CoveredCallsChain.put(%{
        listings: [
          CoveredCallsChain.listing(%{
            amount: amount,
            filled: 0,
            strike: answer.strike_per_token,
            premium: answer.premium_per_token,
            expiry: answer.expiry
          })
        ]
      })

      assert {:ok, bought} =
               CoveredCalls.prepare_covered_call(
                 "AMZNc",
                 :fill,
                 %{signer: context.wallet, listing_id: 1, amount: amount},
                 actor: context.actor
               )

      assert Map.take(bought.facts, [:premium, :fee, :strike]) ==
               Map.take(answer.receipt, [:premium, :fee, :strike])
    end
  end
end
