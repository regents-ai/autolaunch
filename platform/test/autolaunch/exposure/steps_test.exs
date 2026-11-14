defmodule Autolaunch.Exposure.StepsTest do
  @moduledoc """
  The wallet steps for Isolated Exposure to After-hours Stocks, built from the
  week's state at the latest block: exact calldata, an exact approval first,
  the reason a press is certain to fail named from the chain, Update prices
  never blocked, and steps only for a wallet of the acting account.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.{Exposure, ExposureChain}
  alias RegentChain.{BuilderCode, Call}

  @week ExposureChain.week()
  @series ExposureChain.series()
  @factory ExposureChain.factory()
  @stock ExposureChain.stock()
  @unit ExposureChain.unit()
  @wad ExposureChain.wad()
  @boundaries ExposureChain.boundaries()
  @usdc ExposureChain.usdc()
  @router ExposureChain.router()
  @pool_factory "0x420dd381b31aef6683db6b902084cb0ffece40da"
  @swap "swapExactTokensForTokens(uint256,uint256,(address,address,bool,address)[],address,uint256)"

  setup :bidder

  setup do
    ExposureChain.install()
  end

  defp prepare(context, kind, request \\ %{}, week \\ @week),
    do:
      Exposure.prepare_exposure(week, kind, Map.put(request, :signer, context.wallet),
        actor: context.actor
      )

  test "buying a token is an exact USDC approval to the router, then a swap through its pool taking at least the quote less 2%",
       context do
    overnight = ExposureChain.overnight()
    assert {:ok, prepared} = prepare(context, :buy, %{leg: :overnight, amount: 25_000_000})
    assert [approval, buy] = prepared.steps
    assert approval.step == "usdc_approval" and approval.to == @usdc

    assert approval.data ==
             BuilderCode.append(Call.encode("approve(address,uint256)", [@router, 25_000_000]))

    # The stub's pool quotes 2.64 for any amount: at least 2.5872 (98%).
    assert prepared.facts.expected == 2_640_000 and prepared.facts.minimum == 2_587_200
    assert buy.step == "buy" and buy.to == @router

    assert buy.data ==
             BuilderCode.append(
               Call.encode(@swap, [
                 25_000_000,
                 2_587_200,
                 [{@usdc, overnight, false, @pool_factory}],
                 context.wallet,
                 ExposureChain.now() + 1_200
               ])
             )

    assert {prepared.blocked, prepared.approved} == {:not_enough_usdc, false}

    ExposureChain.put(%{wallet: %{usdc: 25_000_000}})

    assert {:ok, %{blocked: :approve_first}} =
             prepare(context, :buy, %{leg: :overnight, amount: 25_000_000})

    ExposureChain.put(%{wallet: %{usdc: 25_000_000, usdc_allowance: 25_000_000}})

    assert {:ok, %{blocked: nil, approved: true}} =
             prepare(context, :buy, %{leg: :overnight, amount: 25_000_000})
  end

  test "selling a token swaps it for USDC, and is blocked by holding too little or a pool without liquidity",
       context do
    session = ExposureChain.session()
    ExposureChain.put(%{week: %{mine: {0, 3_000_000}}, wallet: %{leg_allowance: 3_000_000}})

    assert {:ok, prepared} = prepare(context, :sell, %{leg: :session, amount: 3_000_000})
    assert [approval, sell] = prepared.steps
    assert approval.step == "token_approval" and approval.to == session
    assert sell.step == "sell"

    # The stub's Market-hours pool quotes 2.51 USDC: at least 2.4598 (98%).
    assert sell.data ==
             BuilderCode.append(
               Call.encode(@swap, [
                 3_000_000,
                 2_459_800,
                 [{session, @usdc, false, @pool_factory}],
                 context.wallet,
                 ExposureChain.now() + 1_200
               ])
             )

    assert prepared.blocked == nil

    assert {:ok, %{blocked: :more_than_held}} =
             prepare(context, :sell, %{leg: :session, amount: 4_000_000})

    ExposureChain.put(%{
      week: %{mine: {0, 3_000_000}, pools: %{overnight: 2_640_000, session: nil}},
      wallet: %{leg_allowance: 3_000_000}
    })

    assert {:ok, %{blocked: :no_liquidity}} =
             prepare(context, :sell, %{leg: :session, amount: 3_000_000})

    ExposureChain.put(%{week: %{pools: %{}}})

    assert {:ok, %{blocked: :no_liquidity}} =
             prepare(context, :buy, %{leg: :overnight, amount: 1})

    assert {:error, error} = prepare(context, :buy, %{amount: 1})
    assert Exposure.reason(error) == :leg_required
  end

  test "a deposit is an exact stock approval to the factory then the factory's deposit for the week, blocked until the approval is on the chain",
       context do
    assert {:ok, prepared} = prepare(context, :deposit, %{amount: 5_000_000})
    assert [approval, deposit] = prepared.steps
    assert approval.step == "stock_approval" and approval.to == @stock

    assert approval.data ==
             BuilderCode.append(Call.encode("approve(address,uint256)", [@factory, 5_000_000]))

    assert deposit.step == "deposit" and deposit.to == @factory

    assert deposit.data ==
             BuilderCode.append(Call.encode("deposit(uint256,uint256)", [@week, 5_000_000]))

    assert {prepared.blocked, prepared.approved} == {:approve_first, false}
    assert prepared.facts == %{amount: 5_000_000, room: 30_000_000}

    ExposureChain.put(%{wallet: %{allowance: 5_000_000}})

    assert {:ok, %{blocked: nil, approved: true}} =
             prepare(context, :deposit, %{amount: 5_000_000})
  end

  test "the first deposit of a week not open yet opens it, unless opening is paused", context do
    ExposureChain.put(%{week: %{opened: false}, wallet: %{allowance: 5_000_000}})

    assert {:ok, %{blocked: nil, steps: [_approval, deposit], facts: %{room: 40_000_000}}} =
             prepare(context, :deposit, %{amount: 5_000_000})

    assert deposit.to == @factory

    ExposureChain.put(%{week: %{opened: false}, paused: true, wallet: %{allowance: 5_000_000}})

    assert {:ok, %{blocked: :paused}} = prepare(context, :deposit, %{amount: 5_000_000})

    # Pausing stops new weeks opening; a week already open takes deposits as before.
    ExposureChain.put(%{paused: true, wallet: %{allowance: 5_000_000}})

    assert {:ok, %{blocked: nil}} = prepare(context, :deposit, %{amount: 5_000_000})
  end

  test "a deposit is blocked by what the chain says now: closed, ended, waiting on its first price, past the cap, short, or too little stock",
       context do
    last = List.last(@boundaries)

    for {chain, reason} <- [
          {%{now: last}, :deposits_closed},
          {%{week: %{status: 2, end_reason: 4}}, :ended},
          {%{week: %{status: 0, prices: []}}, :not_open},
          {%{week: %{held: 9_000_000}}, :backing_short},
          {%{week: %{accounted: 36_000_000, held: 36_000_000}}, :above_cap},
          {%{wallet: %{stock: 1_000_000, allowance: 40_000_000}}, :not_enough_stock}
        ] do
      ExposureChain.put(Map.put_new(chain, :wallet, %{allowance: 40_000_000}))
      assert {:ok, %{blocked: ^reason}} = prepare(context, :deposit, %{amount: 5_000_000})
    end

    # A past week takes no deposits: its last close has passed.
    ExposureChain.put(%{
      weeks: %{(@week - 1) => %{status: 2, end_reason: 1}},
      wallet: %{allowance: 40_000_000}
    })

    assert {:ok, %{blocked: :deposits_closed}} =
             prepare(context, :deposit, %{amount: 5_000_000}, @week - 1)
  end

  test "before the end only whole pairs return, one stock token each", context do
    ExposureChain.put(%{week: %{mine: {3_000_000, 2_000_000}}})

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
      week: %{
        status: 2,
        end_reason: 1,
        prices: Enum.map([160, 172, 166, 178, 170], &(&1 * @wad)),
        mine: {1_000_000, 0}
      }
    })

    assert {:ok, prepared} = prepare(context, :redeem, %{overnight: 1_000_000, session: 0})
    assert prepared.blocked == nil
    assert prepared.facts.paid == div(1_000_000 * 104, 170)
  end

  test "a single token returns once the prices waiting to be applied end the week", context do
    # The series has not written its end yet; redeeming applies it first.
    ExposureChain.put(%{
      week: %{
        status: 2,
        end_reason: 1,
        chain_status: 1,
        prices: Enum.map([160, 172, 166, 178], &(&1 * @wad)),
        due: [170 * @wad],
        mine: {1_000_000, 0}
      }
    })

    assert {:ok, %{blocked: nil, facts: %{paid: paid}}} =
             prepare(context, :redeem, %{overnight: 1_000_000, session: 0})

    assert paid == div(1_000_000 * 104, 170)
  end

  test "after a seizure every return is cut by the same fraction", context do
    ExposureChain.put(%{week: %{held: 5_000_000, mine: {2_000_000, 2_000_000}}})

    assert {:ok, %{facts: %{paid: 1_000_000}, blocked: nil}} =
             prepare(context, :redeem, %{overnight: 2_000_000, session: 2_000_000})

    ExposureChain.put(%{week: %{held: 0, mine: {2_000_000, 2_000_000}}})

    assert {:ok, %{blocked: :backing_short}} =
             prepare(context, :redeem, %{overnight: 2_000_000, session: 2_000_000})
  end

  test "an amount that comes to nothing is refused", context do
    assert {:error, error} = prepare(context, :redeem, %{overnight: 0, session: 0})
    assert Exposure.reason(error) == :invalid_amount

    # A deposit of nothing is not an input the action takes.
    assert {:error, %Ash.Error.Invalid{}} = prepare(context, :deposit, %{amount: 0})
  end

  test "Update prices is settle on the series, never blocked, and says what it would apply",
       context do
    assert {:ok, prepared} = prepare(context, :settle)
    assert [%{step: "settle", to: @series, data: data}] = prepared.steps
    assert data == BuilderCode.append(Call.encode("settle()", []))
    assert {prepared.blocked, prepared.approved} == {nil, true}

    close = Enum.at(@boundaries, 2)

    assert prepared.facts == %{
             due: 0,
             ends: false,
             next: %{index: 2, at: close, kind: :close, applies_at: close + 3_600}
           }

    ExposureChain.put(%{now: close + 3_700, week: %{due: [257 * @wad]}})
    assert {:ok, %{blocked: nil, facts: %{due: 1, ends: false}}} = prepare(context, :settle)

    # A price that ends the week: one token's value would reach zero.
    ExposureChain.put(%{
      now: close + 3_700,
      week: %{status: 2, end_reason: 3, chain_status: 1, due: [130 * @wad]}
    })

    assert {:ok, %{blocked: nil, facts: %{due: 1, ends: true}}} = prepare(context, :settle)

    # Once the week has ended on the chain there is nothing left to apply.
    ExposureChain.put(%{
      week: %{status: 2, end_reason: 1, prices: List.duplicate(250 * @wad, 11)}
    })

    assert {:ok, %{blocked: nil, facts: %{due: 0, ends: false, next: nil}}} =
             prepare(context, :settle)
  end

  test "steps are built only for one of the acting account's own wallets", context do
    assert {:error, error} =
             Exposure.prepare_exposure(
               @week,
               :deposit,
               %{amount: 1, signer: "0x9999999999999999999999999999999999999999"},
               actor: context.actor
             )

    assert Exposure.reason(error) == :wrong_signer

    assert {:error, _forbidden} = Exposure.prepare_exposure(@week, :deposit, %{amount: 1})
  end

  test "a week that is neither this week nor open is refused, and a week not open yet has no tokens to trade",
       context do
    for week <- [@week - 1, @week + 1] do
      assert {:error, error} = prepare(context, :deposit, %{amount: 1}, week)
      assert Exposure.reason(error) == :unknown_week
    end

    ExposureChain.put(%{week: %{opened: false}})

    for {kind, request} <- [
          redeem: %{overnight: 1, session: 1},
          buy: %{leg: :overnight, amount: 1},
          sell: %{leg: :session, amount: 1},
          settle: %{}
        ] do
      assert {:error, error} = prepare(context, kind, request)
      assert Exposure.reason(error) == :week_not_open
    end
  end

  test "a holding reads the wallet's tokens and what it can return now", context do
    ExposureChain.put(%{week: %{mine: {3 * @unit, 2 * @unit}}})

    assert {:ok, holdings} =
             Exposure.exposure_holdings(@week, %{wallet: context.wallet}, actor: context.actor)

    assert holdings.redeemable == %{overnight: 2 * @unit, session: 2 * @unit, paid: 2 * @unit}

    assert {holdings.overnight, holdings.session, holdings.stock} ==
             {3 * @unit, 2 * @unit, 50_000_000}
  end
end
