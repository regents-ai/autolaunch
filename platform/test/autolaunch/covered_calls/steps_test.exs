defmodule Autolaunch.CoveredCalls.StepsTest do
  @moduledoc """
  The wallet steps for covered calls, built from the contract's state at the
  latest block: exact calldata, an exact approval first, the reason a press is
  certain to fail named from the chain, and steps only for a wallet of the
  acting account.
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

  test "an expiry that is not a Friday at 21:00 UTC is refused, not blocked", context do
    chain(%{})

    assert {:error, error} =
             prepare(context, :list, %{
               amount: @unit,
               strike_per_token: 1,
               premium_per_token: 1,
               expiry: @expiry + 3_600
             })

    assert CoveredCalls.reason(error) == :not_a_weekly_expiry
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

    assert {:ok, %{blocked: :outside_exercise_window}} =
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
end
