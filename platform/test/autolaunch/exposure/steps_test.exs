defmodule Autolaunch.Exposure.StepsTest do
  @moduledoc """
  The wallet steps for Afterhours Exposed Tokens, built from the series' state
  at the latest block: exact calldata, an exact approval first, the reason a
  press is certain to fail named from the chain, the round of the pinned feed
  phase in force at a price's moment, and steps only for a wallet of the
  acting account.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.{Exposure, ExposureChain}
  alias RegentChain.{BuilderCode, Call}

  @series ExposureChain.series()
  @stock ExposureChain.stock()
  @oracle ExposureChain.oracle()
  @unit ExposureChain.unit()
  @wad ExposureChain.wad()
  @boundaries ExposureChain.boundaries()

  setup :bidder

  setup do
    ExposureChain.install()
  end

  defp prepare(context, kind, request \\ %{}),
    do:
      Exposure.prepare_exposure(@series, kind, Map.put(request, :signer, context.wallet),
        actor: context.actor
      )

  defp holding(overrides),
    do: Map.merge(%{stock: 50_000_000, allowance: 0, overnight: 0, session: 0}, overrides)

  test "minting is an exact stock approval then mint, blocked until the approval is on the chain",
       context do
    assert {:ok, prepared} = prepare(context, :mint, %{amount: 5_000_000})
    assert [approval, mint] = prepared.steps
    assert approval.step == "stock_approval" and approval.to == @stock

    assert approval.data ==
             BuilderCode.append(Call.encode("approve(address,uint256)", [@series, 5_000_000]))

    assert mint.to == @series
    assert mint.data == BuilderCode.append(Call.encode("mint(uint256)", [5_000_000]))
    assert {prepared.blocked, prepared.approved} == {:approve_first, false}

    ExposureChain.put(%{wallet: holding(%{allowance: 5_000_000})})
    assert {:ok, %{blocked: nil, approved: true}} = prepare(context, :mint, %{amount: 5_000_000})
  end

  test "minting is blocked by what the chain says now: not open, past the cap, short, or too little stock",
       context do
    ready = holding(%{allowance: 40_000_000})

    for {chain, reason} <- [
          {%{status: 0, prices: []}, :not_open},
          {%{status: 2}, :ended},
          {%{held: 9_000_000}, :backing_short},
          {%{accounted: 36_000_000, held: 36_000_000}, :above_cap},
          {%{wallet: holding(%{stock: 1_000_000, allowance: 40_000_000})}, :not_enough_stock}
        ] do
      ExposureChain.put(Map.put_new(chain, :wallet, ready))
      assert {:ok, %{blocked: ^reason}} = prepare(context, :mint, %{amount: 5_000_000})
    end
  end

  test "before the end only whole pairs return, one stock token each", context do
    ExposureChain.put(%{wallet: holding(%{overnight: 3_000_000, session: 2_000_000})})

    assert {:ok, prepared} =
             prepare(context, :redeem, %{overnight: 2_000_000, session: 2_000_000})

    assert prepared.blocked == nil
    assert prepared.facts.paid == 2_000_000

    assert [%{step: "redeem", to: @series, data: data}] = prepared.steps

    assert data ==
             BuilderCode.append(Call.encode("redeem(uint256,uint256)", [2_000_000, 2_000_000]))

    assert {:ok, %{blocked: :pair_required}} =
             prepare(context, :redeem, %{overnight: 3_000_000, session: 2_000_000})

    assert {:ok, %{blocked: :more_than_held}} =
             prepare(context, :redeem, %{overnight: 3_000_000, session: 3_000_000})
  end

  test "after the end each token returns its share of the last price, rounding down", context do
    # Close 170 with After-hours 104 and Market-hours 66, as in the paper.
    ExposureChain.put(%{
      status: 2,
      end_reason: 1,
      prices: Enum.map([160, 172, 166, 178, 170], &(&1 * @wad)),
      wallet: holding(%{overnight: 1_000_000, session: 0})
    })

    assert {:ok, prepared} = prepare(context, :redeem, %{overnight: 1_000_000, session: 0})
    assert prepared.blocked == nil
    assert prepared.facts.paid == div(1_000_000 * 104, 170)
  end

  test "after a seizure every return is cut by the same fraction", context do
    ExposureChain.put(%{
      held: 5_000_000,
      accounted: 10_000_000,
      wallet: holding(%{overnight: 2_000_000, session: 2_000_000})
    })

    assert {:ok, %{facts: %{paid: 1_000_000}, blocked: nil}} =
             prepare(context, :redeem, %{overnight: 2_000_000, session: 2_000_000})

    ExposureChain.put(%{
      held: 0,
      accounted: 10_000_000,
      wallet: holding(%{overnight: 2_000_000, session: 2_000_000})
    })

    assert {:ok, %{blocked: :backing_short}} =
             prepare(context, :redeem, %{overnight: 2_000_000, session: 2_000_000})
  end

  test "an amount that comes to nothing is refused", context do
    assert {:error, error} = prepare(context, :redeem, %{overnight: 0, session: 0})
    assert Exposure.reason(error) == :invalid_amount
  end

  test "the next price is recorded from the round of the pinned phase in force at its time, then applied",
       context do
    close = Enum.at(@boundaries, 2)

    # Rounds updated every 20 minutes through Monday; the one in force at the close is 15:50.
    rounds =
      for minutes <- 0..40, do: {close - 7_200 + minutes * 1_200 - 600, 25_000_000_000 + minutes}

    ExposureChain.put(%{now: close + 3_700, rounds: rounds})

    assert {:ok, prepared} = prepare(context, :update)
    assert prepared.blocked == nil
    assert [record, settle] = prepared.steps
    assert record.to == @oracle

    in_force = Enum.find_index(rounds, fn {at, _answer} -> at > close end)
    {updated_at, _answer} = Enum.at(rounds, in_force - 1)
    assert updated_at <= close

    assert record.data ==
             BuilderCode.append(
               Call.encode("record(uint64,bool,uint64)", [close, false, in_force])
             )

    assert settle == %{
             settle
             | to: @series,
               data: BuilderCode.append(Call.encode("settle()", []))
           }
  end

  test "a price recorded already is only applied", context do
    close = Enum.at(@boundaries, 2)
    ExposureChain.put(%{now: close + 3_700, recorded: %{close => 251 * @wad}})

    assert {:ok, %{blocked: nil, steps: [%{step: "settle"}]}} = prepare(context, :update)
  end

  test "recording is blocked until an hour after the price's time, and for a feed silent too long",
       context do
    assert {:ok, %{blocked: :too_early}} = prepare(context, :update)

    close = Enum.at(@boundaries, 2)
    ExposureChain.put(%{now: close + 3_700, rounds: [{close - 85 * 3_600, 25_000_000_000}]})
    assert {:ok, %{blocked: :price_too_old}} = prepare(context, :update)
  end

  test "a series can be ended only once its next price's recording window has passed", context do
    assert {:ok, %{blocked: :not_overdue, steps: [%{step: "end"}]}} = prepare(context, :end)

    close = Enum.at(@boundaries, 2)
    ExposureChain.put(%{now: close + 7 * 86_400 + 1})
    assert {:ok, %{blocked: nil}} = prepare(context, :end)
    assert {:ok, %{blocked: :missed_deadline}} = prepare(context, :update)
  end

  test "steps are built only for one of the acting account's own wallets", context do
    assert {:error, error} =
             Exposure.prepare_exposure(
               @series,
               :mint,
               %{amount: 1, signer: "0x9999999999999999999999999999999999999999"},
               actor: context.actor
             )

    assert Exposure.reason(error) == :wrong_signer

    assert {:error, _forbidden} = Exposure.prepare_exposure(@series, :mint, %{amount: 1})
  end

  test "a series the site doesn't list is refused", context do
    assert {:error, error} =
             Exposure.prepare_exposure(
               "0x1234567890123456789012345678901234567890",
               :mint,
               %{amount: 1, signer: context.wallet},
               actor: context.actor
             )

    assert Exposure.reason(error) == :unknown_series
  end

  test "a holding reads the wallet's tokens and what it can return now", context do
    ExposureChain.put(%{wallet: holding(%{overnight: 3 * @unit, session: 2 * @unit})})

    assert {:ok, holdings} =
             Exposure.exposure_holdings(@series, %{wallet: context.wallet}, actor: context.actor)

    assert holdings.redeemable == %{overnight: 2 * @unit, session: 2 * @unit, paid: 2 * @unit}
  end
end
