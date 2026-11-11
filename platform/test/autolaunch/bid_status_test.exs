defmodule Autolaunch.BidStatusTest do
  @moduledoc """
  A bid's status only moves forward along its settlement, and a finished bid
  stays finished, whatever order readings and receipts arrive in.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.Bid

  @statuses [:active, :returnable, :awaiting_claim, :claimable, :returned, :claimed]

  test "the paths a bid takes all move forward" do
    for path <- [
          [:active, :returnable, :returned],
          [:active, :returnable, :awaiting_claim, :claimable, :claimed],
          [:active, :returnable, :claimable, :claimed],
          [:active, :awaiting_claim, :claimable, :claimed]
        ] do
      assert path
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> Bid.forward?(a, b) end)
    end
  end

  test "claimed is final, and nothing moves back to active" do
    refute Enum.any?(@statuses, &Bid.forward?(:claimed, &1))
    refute Enum.any?(@statuses, &Bid.forward?(&1, :active))
  end

  property "applying writes in any order ends no earlier than the furthest step written" do
    check all(writes <- list_of(member_of(@statuses), min_length: 1, max_length: 12)) do
      final =
        Enum.reduce(writes, :active, fn next, current ->
          if Bid.forward?(current, next), do: next, else: current
        end)

      assert Enum.all?(writes, &(&1 == final or not Bid.forward?(final, &1)))
    end
  end
end
