defmodule Autolaunch.Earn.StatesTest do
  @moduledoc """
  Earn's state machines, each derived from chain facts at one block: every
  state each one reaches, the boundary between neighbouring states, what each
  market status allows, and the order the blocked reasons are checked in.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.Earn.States

  @ray 10 ** 27

  test "market status: inactive outranks paused, paused outranks frozen, and only a clear market is open" do
    assert States.status(%{active: false, paused: true, frozen: true}) == :inactive
    assert States.status(%{active: false, paused: false, frozen: false}) == :inactive
    assert States.status(%{active: true, paused: true, frozen: true}) == :paused
    assert States.status(%{active: true, paused: true, frozen: false}) == :paused
    assert States.status(%{active: true, paused: false, frozen: true}) == :frozen
    assert States.status(%{active: true, paused: false, frozen: false}) == :open
  end

  test "what each market status allows: frozen lets balances out and nothing in" do
    allowed =
      for status <- [:open, :frozen, :paused, :inactive],
          kind <- States.kinds(),
          into: %{},
          do: {{status, kind}, States.allows?(status, kind)}

    assert allowed == %{
             {:open, :deposit} => true,
             {:open, :withdraw} => true,
             {:frozen, :deposit} => false,
             {:frozen, :withdraw} => true,
             {:paused, :deposit} => false,
             {:paused, :withdraw} => false,
             {:inactive, :deposit} => false,
             {:inactive, :withdraw} => false
           }
  end

  test "deposit capacity: no cap is uncapped, capacity shrinks to a single unit, then the market is full" do
    at_par = %{cap: 1_000, decimals: 6, index: @ray}

    assert States.capacity(%{cap: 0, decimals: 6, scaled: 10 ** 30, index: @ray}) == :uncapped
    assert States.capacity(Map.put(at_par, :scaled, 0)) == {:left, 1_000_000_000}
    assert States.capacity(Map.put(at_par, :scaled, 999_999_999)) == {:left, 1}
    assert States.capacity(Map.put(at_par, :scaled, 1_000_000_000)) == :full
    # The treasury's share can carry the scaled total past the cap.
    assert States.capacity(Map.put(at_par, :scaled, 1_000_000_001)) == :full
  end

  test "deposit capacity at an income index of 1.5 counts the pool's rounding down, one unit past the cap" do
    # 1,000,000,001 units scale down to 666,666,667, whose balance rounds down
    # to exactly the cap; one unit more scales to 666,666,668, past it.
    assert States.capacity(%{cap: 1_000, decimals: 6, scaled: 0, index: div(3 * @ray, 2)}) ==
             {:left, 1_000_000_001}
  end

  property "deposit capacity is the largest deposit the pool's own cap check lets through" do
    check all(
            cap <- integer(1..100_000_000),
            decimals <- integer(0..18),
            index <- integer(@ray..(2 * @ray)),
            share <- integer(0..110),
            wiggle <- integer(-3..3)
          ) do
      limit = cap * 10 ** decimals
      scaled = max(div(limit * @ray * share, index * 100) + wiggle, 0)

      # `ValidationLogic.validateSupply` from Aave V3.5 on, at this index.
      passes? = fn units -> div((scaled + div(units * @ray, index)) * index, @ray) <= limit end

      case States.capacity(%{cap: cap, decimals: decimals, scaled: scaled, index: index}) do
        {:left, left} -> assert passes?.(left) and not passes?.(left + 1)
        :full -> refute passes?.(1)
      end
    end
  end

  test "withdraw availability: available up to what the market holds now, short past it" do
    assert States.availability(500, 500) == :available
    assert States.availability(1, 500) == :available
    assert States.availability(501, 500) == {:short, 500}
    assert States.availability(1, 0) == {:short, 0}
  end

  test "deposit readiness follows the allowance against the amount as it stands" do
    assert States.readiness(100, 0) == :needs_approval
    assert States.readiness(100, 100) == :approved
    assert States.readiness(100, 2 ** 256 - 1) == :approved
    # The amount edited upwards after the approval landed.
    assert States.readiness(101, 100) == :needs_approval
    # The allowance spent or changed elsewhere.
    assert States.readiness(100, 99) == :needs_approval
  end

  test "withdraw amount kind: everything only by name, and it is sent as the largest amount" do
    assert States.withdrawal(:everything) == :everything
    assert States.withdrawal(40) == {:amount, 40}
    assert States.withdraw_units(:everything) == 2 ** 256 - 1
    assert States.withdraw_units({:amount, 40}) == 40
  end

  test "position: only zero is none; a single unit of dust is held" do
    assert States.position(0) == :none
    assert States.position(1) == {:held, 1}
    assert States.position(250_000_000) == {:held, 250_000_000}
  end

  @deposit %{kind: :deposit, status: :open, units: 100, funds: 100, capacity: :uncapped}
  @withdraw %{
    kind: :withdraw,
    status: :open,
    position: {:held, 100},
    withdrawal: {:amount, 100},
    liquidity: 100
  }

  test "a deposit is blocked by the first that fails: market, then the wallet's USDC, then the cap" do
    assert States.blocked(@deposit) == :ok
    assert States.blocked(%{@deposit | capacity: {:left, 100}}) == :ok

    everything_wrong = %{@deposit | funds: 99, capacity: :full}

    assert States.blocked(%{everything_wrong | status: :inactive}) == {:blocked, :market_inactive}
    assert States.blocked(%{everything_wrong | status: :paused}) == {:blocked, :market_paused}
    assert States.blocked(%{everything_wrong | status: :frozen}) == {:blocked, :market_frozen}
    assert States.blocked(everything_wrong) == {:blocked, :not_enough_usdc}
    assert States.blocked(%{everything_wrong | funds: 100}) == {:blocked, :over_supply_cap}
    assert States.blocked(%{@deposit | capacity: {:left, 99}}) == {:blocked, :over_supply_cap}
  end

  test "a withdrawal is blocked by the first that fails: market, then the balance, then what is available" do
    assert States.blocked(@withdraw) == :ok
    assert States.blocked(%{@withdraw | status: :frozen}) == :ok

    everything_wrong = %{@withdraw | withdrawal: {:amount, 101}, liquidity: 0}

    assert States.blocked(%{everything_wrong | status: :inactive}) == {:blocked, :market_inactive}
    assert States.blocked(%{everything_wrong | status: :paused}) == {:blocked, :market_paused}
    assert States.blocked(everything_wrong) == {:blocked, :over_balance}

    assert States.blocked(%{everything_wrong | withdrawal: {:amount, 100}}) ==
             {:blocked, :not_available_now}

    # Everything is the balance at this block, measured against what is available.
    assert States.blocked(%{@withdraw | withdrawal: :everything}) == :ok

    assert States.blocked(%{@withdraw | withdrawal: :everything, liquidity: 99}) ==
             {:blocked, :not_available_now}

    assert States.blocked(%{@withdraw | withdrawal: :everything, position: :none}) ==
             {:blocked, :over_balance}
  end
end
