defmodule Autolaunch.Exposure.LedgerTest do
  @moduledoc """
  The series arithmetic the pages show, against the rules the contract keeps
  for every price path: the two ledgers always add up to the price, neither is
  ever negative, a series ends exactly when one would reach zero, and no
  redemption ever owes more than the stock behind the tokens returned.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.Exposure.Ledger

  @wad 1_000_000_000_000_000_000

  test "the paper's worked example: 160, 172, 166, 178, 170 leaves After-hours 104 and Market-hours 66" do
    path = Ledger.path(Enum.map([160, 172, 166, 178, 170], &(&1 * @wad)))

    assert Enum.map(path, &{div(&1.night, @wad), div(&1.day, @wad)}) ==
             [{80, 80}, {92, 80}, {92, 74}, {104, 74}, {104, 66}]

    assert Enum.all?(path, &is_nil(&1.ended))
  end

  test "an open below Market-hours' value ends the series with After-hours at zero" do
    assert [_, %{night: 0, day: 70, ended: :overnight_depleted}] = Ledger.path([160, 70, 999])
  end

  test "a close below After-hours' value ends the series with Market-hours at zero" do
    assert [_, _, %{night: 50, day: 0, ended: :session_depleted}] =
             Ledger.path([100, 100, 50, 999])
  end

  property "the ledgers always add up to the price, and neither is ever negative" do
    check all(prices <- list_of(integer(1..1_000_000), min_length: 1, max_length: 40)) do
      for step <- Ledger.path(prices) do
        assert step.night + step.day == step.price
        assert step.night >= 0 and step.day >= 0
      end
    end
  end

  property "a series ends at the first price that empties a ledger, and only then" do
    check all(prices <- list_of(integer(1..1_000), min_length: 1, max_length: 40)) do
      path = Ledger.path(prices)
      {last, before} = List.pop_at(path, -1)

      assert Enum.all?(before, &(is_nil(&1.ended) and &1.night > 0 and &1.day > 0))
      assert length(path) == length(prices) or last.ended != nil
      if last.ended, do: assert(last.night == 0 or last.day == 0)
    end
  end

  property "an open moves only After-hours, and a close moves only Market-hours" do
    check all(prices <- list_of(integer(1..1_000_000), min_length: 2, max_length: 40)) do
      prices
      |> Ledger.path()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [before, step] ->
        if rem(step.index, 2) == 1 and is_nil(step.ended), do: assert(step.day == before.day)
        if rem(step.index, 2) == 0 and is_nil(step.ended), do: assert(step.night == before.night)
      end)
    end
  end

  property "whole pairs redeem exactly, and nothing returned is owed more than the stock behind it" do
    check all(
            price <- integer(1..1_000_000),
            night <- integer(0..price),
            overnight <- integer(0..10_000_000_000),
            session <- integer(0..10_000_000_000)
          ) do
      owed = Ledger.owed(overnight, session, price, night)

      assert Ledger.owed(session, session, price, night) == session
      assert owed >= min(overnight, session)
      assert owed <= max(overnight, session)
      # Every holder together is owed at most the stock behind all the tokens.
      assert Ledger.owed(overnight, 0, price, night) + Ledger.owed(0, overnight, price, night) <=
               overnight
    end
  end

  property "after a seizure everyone is cut by the same fraction, rounding down" do
    check all(
            accounted <- integer(1..10_000_000_000),
            balance <- integer(0..accounted),
            owed <- integer(0..accounted)
          ) do
      paid = Ledger.paid(owed, balance, accounted)
      assert paid <= owed
      assert paid * accounted <= owed * balance
      assert Ledger.paid(owed, accounted, accounted) == owed
    end
  end
end
