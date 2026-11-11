defmodule Autolaunch.CoveredCalls.StepsTest do
  @moduledoc """
  The wallet steps for covered calls and bids, built from the contract's state
  at the latest block: exact calldata, an exact approval first, the reason a
  press is certain to fail named from the chain, and steps only for a wallet of
  the acting account.
  """

  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.{CoveredCalls, CoveredCallsChain}
  alias Autolaunch.CoveredCalls.Terms
  alias RegentChain.{BuilderCode, Call}

  @seller "0x2222222222222222222222222222222222222222"
  @stock CoveredCallsChain.stock()
  @contract CoveredCallsChain.contract()
  @usdc CoveredCallsChain.usdc()
  @unit CoveredCallsChain.unit()
  @now CoveredCallsChain.now()

  setup :bidder

  setup do
    CoveredCallsChain.install()
  end

  @expiry hd(Terms.expiries(@now))

  defp chain(overrides) do
    {listing, overrides} = Map.pop(overrides, :listing, CoveredCallsChain.listing(%{}))
    CoveredCallsChain.put(Map.put(overrides, :listings, [listing]))
  end

  defp listing(overrides), do: CoveredCallsChain.listing(overrides)

  defp bid(overrides), do: CoveredCallsChain.bid(overrides)

  defp prepare(context, kind, request),
    do:
      CoveredCalls.prepare_covered_call("AMZNc", kind, Map.put(request, :signer, context.wallet),
        actor: context.actor
      )

  test "a listing is an exact stock approval then list, blocked until the approval is on the chain",
       context do
    chain(%{})

    assert {:ok, prepared} =
             prepare(context, :list, %{
               amount: 2 * @unit,
               strike_per_token: 260_000_000,
               premium_per_token: 4_000_000,
               expiry: @expiry
             })

    assert [approval, list] = prepared.steps
    assert approval.step == "stock_approval" and approval.to == @stock

    assert approval.data ==
             BuilderCode.append(Call.encode("approve(address,uint256)", [@contract, 2 * @unit]))

    assert list.to == @contract

    assert list.data ==
             BuilderCode.append(
               Call.encode("list(uint256,uint256,uint256,uint64)", [
                 2 * @unit,
                 260_000_000,
                 4_000_000,
                 @expiry
               ])
             )

    assert prepared.blocked == :approve_first and prepared.approved == false

    chain(%{allowance: 2 * @unit})

    assert {:ok, %{blocked: nil, approved: true}} =
             prepare(context, :list, %{
               amount: 2 * @unit,
               strike_per_token: 260_000_000,
               premium_per_token: 4_000_000,
               expiry: @expiry
             })
  end

  test "a listing is blocked by too little stock or a corporate action before the window closes",
       context do
    request = %{
      amount: 20 * @unit,
      strike_per_token: 260_000_000,
      premium_per_token: 4_000_000,
      expiry: @expiry
    }

    chain(%{allowance: 20 * @unit})
    assert {:ok, %{blocked: :not_enough_stock}} = prepare(context, :list, request)

    chain(%{allowance: 2 * @unit, effective_at: @expiry + 3_600})

    assert {:ok, %{blocked: :corporate_action}} =
             prepare(context, :list, %{request | amount: 2 * @unit})

    chain(%{allowance: 2 * @unit, effective_at: @expiry + Terms.exercise_window()})
    assert {:ok, %{blocked: nil}} = prepare(context, :list, %{request | amount: 2 * @unit})
  end

  test "an expiry the site does not offer is refused, not blocked: not a Friday close, or past the four offered",
       context do
    chain(%{})
    request = %{amount: @unit, strike_per_token: 1, premium_per_token: 1}

    for expiry <- [@expiry + 3_600, Enum.at(Terms.expiries(@now, 5), 4)] do
      assert {:error, error} = prepare(context, :list, Map.put(request, :expiry, expiry))
      assert CoveredCalls.reason(error) == :expiry_not_offered
    end
  end

  test "a listing or bid already made for a Friday the site leaves out can still be bought and sold into",
       context do
    # Juneteenth, Friday 19 June 2026: NYSE is shut, so no new listing or bid takes it.
    juneteenth = DateTime.to_unix(~U[2026-06-19 21:00:00Z])

    chain(%{
      listing: listing(%{expiry: juneteenth}),
      bids: [bid(%{expiry: juneteenth})],
      usdc_allowance: 10_000_000_000,
      allowance: 6 * @unit
    })

    assert {:ok, %{blocked: nil}} = prepare(context, :fill, %{listing_id: 1, amount: @unit})

    assert {:ok, %{blocked: nil, facts: %{expiry: ^juneteenth}}} =
             prepare(context, :sell_to_bid, %{bid_id: 1, amount: 2 * @unit})
  end

  test "buying pays the premium rounded up and is blocked when not that many are left", context do
    chain(%{usdc_allowance: 10_000_000_000})
    # 1.5 tokens at 3 USDC: 4.5 USDC, fee 1% rounded up.
    assert {:ok, prepared} = prepare(context, :fill, %{listing_id: 1, amount: 150_000_000})
    assert prepared.facts.premium == 4_500_000 and prepared.facts.fee == 45_000
    assert [%{step: "usdc_approval", to: @usdc}, %{step: "fill", data: data}] = prepared.steps
    assert data == BuilderCode.append(Call.encode("fill(uint256,uint256)", [1, 150_000_000]))
    assert prepared.blocked == nil

    assert {:ok, %{blocked: :sold_out}} =
             prepare(context, :fill, %{listing_id: 1, amount: 7 * @unit})

    chain(%{usdc_balance: 1})

    assert {:ok, %{blocked: :not_enough_usdc}} =
             prepare(context, :fill, %{listing_id: 1, amount: @unit})
  end

  test "exercise is blocked outside the 24 hours after expiry and above what is held", context do
    chain(%{held: @unit, usdc_allowance: 10_000_000_000})

    assert {:ok, %{blocked: :exercise_not_open}} =
             prepare(context, :exercise, %{listing_id: 1, amount: @unit})

    chain(%{
      held: @unit,
      usdc_allowance: 10_000_000_000,
      listing: listing(%{expiry: @now - 3_600})
    })

    assert {:ok, %{blocked: nil, facts: %{strike: 260_000_000}}} =
             prepare(context, :exercise, %{listing_id: 1, amount: @unit})

    assert {:ok, %{blocked: :more_than_held}} =
             prepare(context, :exercise, %{listing_id: 1, amount: 2 * @unit})
  end

  test "only the seller's wallet may stop selling or collect the strike", context do
    chain(%{})
    assert {:ok, %{blocked: :not_seller}} = prepare(context, :cancel, %{listing_id: 1})
    assert {:ok, %{blocked: :not_seller}} = prepare(context, :collect_strike, %{listing_id: 1})

    chain(%{listing: listing(%{seller: context.wallet, paid: 5_000_000, collected: 1_000_000})})

    assert {:ok, %{blocked: nil, facts: %{unsold: unsold}}} =
             prepare(context, :cancel, %{listing_id: 1})

    assert unsold == 6 * @unit

    assert {:ok, %{blocked: nil, facts: %{amount: 4_000_000}}} =
             prepare(context, :collect_strike, %{listing_id: 1})
  end

  test "a listing the contract does not hold is refused as unknown, not as a chain failure",
       context do
    chain(%{})

    for kind <- [:fill, :cancel, :exercise, :claim, :collect_strike] do
      assert {:error, error} = prepare(context, kind, %{listing_id: 2, amount: @unit})
      assert CoveredCalls.reason(error) == :unknown_listing
    end
  end

  test "buying is held back while a split or dividend is scheduled before the window closes",
       context do
    chain(%{effective_at: @now + 3_600, usdc_balance: 100_000_000, usdc_allowance: 100_000_000})

    assert {:ok, %{blocked: :corporate_action}} =
             prepare(context, :fill, %{listing_id: 1, amount: @unit})

    chain(%{
      effective_at: @expiry + 2 * 86_400,
      usdc_balance: 100_000_000,
      usdc_allowance: 100_000_000
    })

    assert {:ok, %{blocked: nil}} = prepare(context, :fill, %{listing_id: 1, amount: @unit})
  end

  test "steps are only ever for a wallet of the acting account", context do
    chain(%{})

    assert {:error, error} =
             CoveredCalls.prepare_covered_call("AMZNc", :claim, %{listing_id: 1, signer: @seller},
               actor: context.actor
             )

    assert CoveredCalls.reason(error) == :wrong_signer

    assert {:error, _forbidden} =
             CoveredCalls.prepare_covered_call("AMZNc", :claim, %{listing_id: 1})
  end

  test "a bid is an exact USDC approval of its escrow then bid, with a minimum sale of one whole token or the whole bid",
       context do
    request = %{
      amount: 10 * @unit,
      strike_per_token: 260_000_000,
      premium_per_token: 3_000_000,
      expiry: @expiry
    }

    chain(%{})
    assert {:ok, prepared} = prepare(context, :bid, request)
    assert [approval, posted] = prepared.steps
    assert approval.step == "usdc_approval" and approval.to == @usdc

    assert approval.data ==
             BuilderCode.append(Call.encode("approve(address,uint256)", [@contract, 30_000_000]))

    assert posted.step == "bid" and posted.to == @contract

    assert posted.data ==
             BuilderCode.append(
               Call.encode("bid(uint256,uint256,uint256,uint64,uint256)", [
                 10 * @unit,
                 260_000_000,
                 3_000_000,
                 @expiry,
                 @unit
               ])
             )

    assert prepared.blocked == :approve_first and prepared.approved == false
    assert %{escrow: 30_000_000, min_sale: @unit, expiry: @expiry} = prepared.facts

    # Less than a whole token: the minimum sale is the whole bid, and the escrow rounds up.
    half = div(@unit, 2) + 1
    assert {:ok, small} = prepare(context, :bid, %{request | amount: half})
    assert small.facts.min_sale == half
    assert small.facts.escrow == Terms.usdc_for(half, 3_000_000, @unit)
    assert small.facts.escrow == 1_500_001

    chain(%{usdc_allowance: 30_000_000})
    assert {:ok, %{blocked: nil, approved: true}} = prepare(context, :bid, request)

    chain(%{usdc_allowance: 30_000_000, usdc_balance: 29_999_999})
    assert {:ok, %{blocked: :not_enough_usdc}} = prepare(context, :bid, request)

    chain(%{usdc_allowance: 30_000_000, effective_at: @expiry + 3_600})
    assert {:ok, %{blocked: :corporate_action}} = prepare(context, :bid, request)

    assert {:error, error} = prepare(context, :bid, %{request | expiry: @expiry + 3_600})
    assert CoveredCalls.reason(error) == :expiry_not_offered
  end

  test "selling into a bid is an exact stock approval then sellToBid, paying its slice of the premium less the fee",
       context do
    # Ten tokens at a 3 USDC premium, four sold: two more are paid 18 - 12 USDC,
    # less 1% of 18 USDC less 1% of 12 USDC.
    chain(%{bids: [bid(%{})]})
    assert {:ok, prepared} = prepare(context, :sell_to_bid, %{bid_id: 1, amount: 2 * @unit})
    assert [approval, sale] = prepared.steps
    assert approval.step == "stock_approval" and approval.to == @stock

    assert approval.data ==
             BuilderCode.append(Call.encode("approve(address,uint256)", [@contract, 2 * @unit]))

    assert sale.step == "sell_to_bid" and sale.to == @contract

    assert sale.data ==
             BuilderCode.append(Call.encode("sellToBid(uint256,uint256)", [1, 2 * @unit]))

    assert prepared.facts == %{
             bid_id: 1,
             amount: 2 * @unit,
             premium: 6_000_000,
             fee: 60_000,
             receive: 5_940_000,
             strike: 520_000_000,
             expiry: @expiry
           }

    assert prepared.blocked == :approve_first

    chain(%{bids: [bid(%{})], allowance: 6 * @unit})

    assert {:ok, %{blocked: nil}} =
             prepare(context, :sell_to_bid, %{bid_id: 1, amount: 2 * @unit})

    assert {:ok, %{blocked: :more_than_bid}} =
             prepare(context, :sell_to_bid, %{bid_id: 1, amount: 6 * @unit + 1})

    assert {:ok, %{blocked: :below_minimum_sale}} =
             prepare(context, :sell_to_bid, %{bid_id: 1, amount: @unit - 1})

    # What is left may always be sold, however small.
    chain(%{bids: [bid(%{filled: 10 * @unit - 7})], allowance: 6 * @unit})
    assert {:ok, %{blocked: nil}} = prepare(context, :sell_to_bid, %{bid_id: 1, amount: 7})

    chain(%{bids: [bid(%{})], allowance: 6 * @unit, balance: @unit})

    assert {:ok, %{blocked: :not_enough_stock}} =
             prepare(context, :sell_to_bid, %{bid_id: 1, amount: 2 * @unit})

    chain(%{bids: [bid(%{})], allowance: 6 * @unit, effective_at: @expiry + 3_600})

    assert {:ok, %{blocked: :corporate_action}} =
             prepare(context, :sell_to_bid, %{bid_id: 1, amount: 2 * @unit})

    chain(%{bids: [bid(%{expiry: @now})], allowance: 6 * @unit})

    assert {:ok, %{blocked: :bid_expired}} =
             prepare(context, :sell_to_bid, %{bid_id: 1, amount: 2 * @unit})
  end

  test "only the bidder's wallet may raise, cancel or refund a bid, and a raise escrows only the premium it adds",
       context do
    chain(%{bids: [bid(%{})]})

    for {kind, request} <- [
          raise_bid: %{bid_id: 1, amount: @unit},
          cancel_bid: %{bid_id: 1},
          refund_bid: %{bid_id: 1}
        ],
        do: assert({:ok, %{blocked: :not_bidder}} = prepare(context, kind, request))

    chain(%{bids: [bid(%{bidder: context.wallet, amount: 10 * @unit + 1, refundable: 0})]})

    # 10 tokens and a unit escrowed 30.000001 USDC; 5 tokens more brings the
    # premium for 15 tokens and a unit to 45.000001, so 15 USDC is added.
    assert {:ok, raised} = prepare(context, :raise_bid, %{bid_id: 1, amount: 5 * @unit})

    assert [%{step: "usdc_approval", data: approve}, %{step: "raise_bid", data: data}] =
             raised.steps

    assert approve ==
             BuilderCode.append(Call.encode("approve(address,uint256)", [@contract, 15_000_000]))

    assert data == BuilderCode.append(Call.encode("raiseBid(uint256,uint256)", [1, 5 * @unit]))
    assert %{blocked: :approve_first, facts: %{escrow: 15_000_000, bid_id: 1}} = raised

    assert {:ok, cancelled} = prepare(context, :cancel_bid, %{bid_id: 1})
    assert cancelled.blocked == nil

    assert [%{step: "cancel_bid", data: data}] = cancelled.steps
    assert data == BuilderCode.append(Call.encode("cancelBid(uint256)", [1]))
    # Six tokens and a unit unsold; their escrow is 30.000001 less the 12 USDC paid out.
    assert cancelled.facts == %{bid_id: 1, unsold: 6 * @unit + 1, released: 18_000_001}

    assert {:ok, %{blocked: :nothing_to_refund}} = prepare(context, :refund_bid, %{bid_id: 1})

    chain(%{bids: [bid(%{bidder: context.wallet, refundable: 18_000_000})]})
    assert {:ok, refund} = prepare(context, :refund_bid, %{bid_id: 1})
    assert %{blocked: nil, facts: %{bid_id: 1, amount: 18_000_000}} = refund
    assert [%{step: "refund_bid", data: data}] = refund.steps
    assert data == BuilderCode.append(Call.encode("refundBid(uint256)", [1]))

    chain(%{bids: [bid(%{bidder: context.wallet, filled: 10 * @unit})]})
    assert {:ok, %{blocked: :nothing_to_cancel}} = prepare(context, :cancel_bid, %{bid_id: 1})

    chain(%{bids: [bid(%{bidder: context.wallet, expiry: @now})], usdc_allowance: 30_000_000})

    assert {:ok, %{blocked: :bid_expired}} =
             prepare(context, :raise_bid, %{bid_id: 1, amount: @unit})
  end

  test "a bid the contract does not hold is refused as unknown, not as a chain failure",
       context do
    chain(%{bids: [bid(%{})]})

    for kind <- [:raise_bid, :cancel_bid, :refund_bid, :sell_to_bid],
        request <- [%{bid_id: 2, amount: @unit}, %{amount: @unit}] do
      assert {:error, error} = prepare(context, kind, request)
      assert CoveredCalls.reason(error) == :unknown_bid
    end
  end
end
