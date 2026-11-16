defmodule Autolaunch.Earn.StepsTest do
  @moduledoc """
  The wallet steps for an Earn deposit or withdrawal, built from the chain at
  the latest block: exact calldata ending with the Builder Code, an exact
  approval first for a deposit, every reason a step is certain to fail named
  from the chain, and steps only for a wallet of the acting account.
  """

  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.{Earn, EarnChain}
  alias RegentChain.{BuilderCode, Call}

  @pool EarnChain.pool()
  @usdc EarnChain.usdc()
  @unit EarnChain.unit()
  @ray EarnChain.ray()

  setup :bidder

  setup do
    EarnChain.install()
  end

  defp prepare(context, kind, request),
    do:
      Earn.prepare_earn_steps(
        "aave-usdc",
        kind,
        Map.put(request, :signer, context.wallet),
        actor: context.actor
      )

  defp blocked(context, kind, request) do
    {:ok, %{blocked: blocked}} = prepare(context, kind, request)
    blocked
  end

  test "a deposit is an exact USDC approval to the pool, then supply for the signer", context do
    assert {:ok, prepared} = prepare(context, :deposit, %{amount: 250 * @unit})
    assert [approval, supply] = prepared.steps
    signer = String.downcase(context.wallet)

    assert approval.step == "usdc_approval" and approval.to == @usdc

    assert approval.data ==
             BuilderCode.append(Call.encode("approve(address,uint256)", [@pool, 250 * @unit]))

    assert supply.step == "supply" and supply.to == @pool

    assert supply.data ==
             BuilderCode.append(
               Call.encode("supply(address,uint256,address,uint16)", [
                 @usdc,
                 250 * @unit,
                 signer,
                 0
               ])
             )

    assert BuilderCode.call(supply.data) ==
             Call.encode("supply(address,uint256,address,uint16)", [@usdc, 250 * @unit, signer, 0])

    assert %{approved: false, blocked: nil, units: 250_000_000, chain: %{chain_id: 8453}} =
             prepared
  end

  test "a deposit is approved only while the allowance covers the amount as it stands now",
       context do
    EarnChain.put(%{allowance: 100 * @unit})

    assert {:ok, %{approved: true, blocked: nil}} =
             prepare(context, :deposit, %{amount: 100 * @unit})

    # The amount edited after the approval landed: the approval no longer covers it.
    assert {:ok, %{approved: false}} = prepare(context, :deposit, %{amount: 150 * @unit})

    # The allowance changed elsewhere, with nothing on this page.
    EarnChain.put(%{allowance: 0})
    assert {:ok, %{approved: false}} = prepare(context, :deposit, %{amount: 100 * @unit})

    # Either way the approval is a step of its own, never a reason to stop.
    assert {:ok, %{steps: [%{step: "usdc_approval"}, %{step: "supply"}], blocked: nil}} =
             prepare(context, :deposit, %{amount: 100 * @unit})
  end

  test "a withdrawal is withdraw to the signer, for an amount or for everything", context do
    EarnChain.put(%{balance: 40 * @unit})
    signer = String.downcase(context.wallet)

    assert {:ok, %{steps: [withdraw], approved: true, blocked: nil} = amount} =
             prepare(context, :withdraw, %{amount: 15 * @unit})

    assert withdraw.step == "withdraw" and withdraw.to == @pool

    assert withdraw.data ==
             BuilderCode.append(
               Call.encode("withdraw(address,uint256,address)", [@usdc, 15 * @unit, signer])
             )

    assert amount.withdrawal == {:amount, 15 * @unit}

    assert {:ok, %{steps: [all], units: units, withdrawal: :everything}} =
             prepare(context, :withdraw, %{everything: true})

    assert units == 40 * @unit

    assert all.data ==
             BuilderCode.append(
               Call.encode("withdraw(address,uint256,address)", [@usdc, 2 ** 256 - 1, signer])
             )
  end

  test "an amount equal to the balance withdraws that amount, not everything", context do
    EarnChain.put(%{balance: 40 * @unit})
    signer = String.downcase(context.wallet)

    assert {:ok, %{withdrawal: {:amount, 40_000_000}, steps: [withdraw]}} =
             prepare(context, :withdraw, %{amount: 40 * @unit})

    assert BuilderCode.call(withdraw.data) ==
             Call.encode("withdraw(address,uint256,address)", [@usdc, 40 * @unit, signer])
  end

  test "a market that is not open blocks what it does not take", context do
    EarnChain.put(%{balance: 40 * @unit, active: false})
    assert blocked(context, :deposit, %{amount: @unit}) == :market_inactive
    assert blocked(context, :withdraw, %{amount: @unit}) == :market_inactive

    EarnChain.put(%{balance: 40 * @unit, paused: true})
    assert blocked(context, :deposit, %{amount: @unit}) == :market_paused
    assert blocked(context, :withdraw, %{everything: true}) == :market_paused

    # Frozen takes no deposits and lets every balance out.
    EarnChain.put(%{balance: 40 * @unit, frozen: true})
    assert blocked(context, :deposit, %{amount: @unit}) == :market_frozen
    assert blocked(context, :withdraw, %{everything: true}) == nil
  end

  test "a deposit is blocked by too little USDC in the wallet", context do
    EarnChain.put(%{usdc: 10 * @unit, allowance: 20 * @unit})
    assert blocked(context, :deposit, %{amount: 10 * @unit}) == nil
    assert blocked(context, :deposit, %{amount: 10 * @unit + 1}) == :not_enough_usdc
  end

  test "a deposit is blocked past the supply cap, the treasury's share and interest counted",
       context do
    # A cap of 1,000 USDC; 900 supplied in scaled units, 50 owed to the
    # treasury, at an index of 1.02: the pool counts (900 + 50) * 1.02 = 969.
    EarnChain.put(%{
      cap: 1_000,
      scaled: 900 * @unit,
      accrued: 50 * @unit,
      index: div(@ray * 102, 100),
      usdc: 1_000 * @unit
    })

    assert blocked(context, :deposit, %{amount: 31 * @unit}) == nil
    assert blocked(context, :deposit, %{amount: 31 * @unit + 1}) == :over_supply_cap

    # At the cap the market takes nothing.
    EarnChain.put(%{cap: 1_000, scaled: 1_000 * @unit, usdc: 1_000 * @unit})
    assert blocked(context, :deposit, %{amount: 1}) == :over_supply_cap
  end

  test "a withdrawal is blocked past the balance and past what the market has now", context do
    EarnChain.put(%{balance: 40 * @unit, available: 30 * @unit})
    assert blocked(context, :withdraw, %{amount: 30 * @unit}) == nil
    assert blocked(context, :withdraw, %{amount: 40 * @unit + 1}) == :over_balance
    assert blocked(context, :withdraw, %{amount: 30 * @unit + 1}) == :not_available_now
    assert blocked(context, :withdraw, %{everything: true}) == :not_available_now

    # Nothing in the market: nothing to withdraw, everything included.
    EarnChain.put(%{balance: 0})
    assert blocked(context, :withdraw, %{everything: true}) == :over_balance
    assert blocked(context, :withdraw, %{amount: 1}) == :over_balance
  end

  test "a blocked step still comes back with its steps", context do
    EarnChain.put(%{paused: true})

    assert {:ok, %{blocked: :market_paused, steps: [_approval, %{step: "supply"}]}} =
             prepare(context, :deposit, %{amount: @unit})
  end

  test "an amount that is not a whole number above zero is refused, never blocked", context do
    assert {:error, %Ash.Error.Invalid{}} = prepare(context, :deposit, %{amount: 0})

    for {kind, request} <- [
          {:deposit, %{everything: true}},
          {:deposit, %{amount: @unit, everything: true}},
          {:deposit, %{}},
          {:withdraw, %{}},
          {:withdraw, %{amount: @unit, everything: true}},
          {:withdraw, %{everything: false}}
        ] do
      assert {:error, error} = prepare(context, kind, request)
      assert Earn.reason(error) == :invalid_amount, inspect({kind, request})
    end
  end

  test "steps are only for the acting account's own wallets, on a product it offers", context do
    assert {:error, error} =
             Earn.prepare_earn_steps(
               "aave-usdc",
               :deposit,
               %{amount: @unit, signer: "0x2222222222222222222222222222222222222222"},
               actor: context.actor
             )

    assert Earn.reason(error) == :wrong_signer

    assert {:error, error} =
             Earn.prepare_earn_steps("nope", :deposit, %{amount: @unit}, actor: context.actor)

    assert Earn.reason(error) == :unknown_product
  end

  test "a chain that can't be read refuses the steps", context do
    EarnChain.put(%{unreadable: true})
    assert {:error, error} = prepare(context, :deposit, %{amount: @unit})
    assert Earn.reason(error) == :chain_unavailable
  end
end
