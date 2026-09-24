defmodule Autolaunch.MarketFeedTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.LabMarketFeed.Projector
  alias Autolaunch.TestSupport

  @head %{binding: :lab, block: %{number: 150, hash: "0x" <> String.duplicate("ab", 32)}}

  defmodule Verifier do
    @moduledoc false
    def verify_head(_head), do: :ok
  end

  describe "state from the launch lifecycle and the auction's schedule" do
    test "a reached minimum never ends bidding; only the end block and migrate do" do
      # Lifecycle 1 is Active: before the start, before the end, after the end.
      assert MarketState.observed(1, 99, 100, 200) == :created
      assert MarketState.observed(1, 150, 100, 200) == :active
      assert MarketState.observed(1, 200, 100, 200) == :ended
      assert MarketState.observed(1, 900, 100, 200) == :ended
      # Only `migrate` sets 2 and 3, whatever the schedule says.
      assert MarketState.observed(2, 150, 100, 200) == :graduated
      assert MarketState.observed(3, 900, 100, 200) == :failed
    end

    test "states move forward only, and a finished state stays" do
      assert MarketState.join(:created, :active) == :active
      assert MarketState.join(:active, :ended) == :ended
      assert MarketState.join(:ended, :graduated) == :graduated
      assert MarketState.join(:ended, :failed) == :failed
      assert MarketState.join(:active, :created) == :active
      assert MarketState.join(:ended, :active) == :ended
      assert MarketState.join(:graduated, :failed) == :graduated
      assert MarketState.join(:failed, :active) == :failed
    end

    test "the feed stores a reached minimum beside the state, and the end block ends it" do
      auction = TestSupport.project_auction(state: :created)

      assert {:ok, [_changed]} =
               Projector.project([snapshot(auction, :active, true)], @head, Verifier)

      assert %{state: :active, minimum_reached: true} = reload(auction)

      assert {:ok, [_changed]} =
               Projector.project([snapshot(auction, :ended, true)], @head, Verifier)

      assert %{state: :ended, minimum_reached: true} = reload(auction)

      # An older reading can never move it back.
      assert {:ok, []} = Projector.project([snapshot(auction, :active, true)], @head, Verifier)
      assert %{state: :ended} = reload(auction)
    end
  end

  defp snapshot(auction, state, minimum_reached) do
    %{
      auction_id: auction.id,
      auction_address: String.downcase(auction.auction_address),
      state: state,
      minimum_reached: minimum_reached,
      current_clearing_price: auction.current_clearing_price,
      price_quote: nil,
      positions: []
    }
  end

  defp reload(auction) do
    {:ok, row} = Autolaunch.get_lab_market_auction_for_update(auction.id, actor: %System{})
    row
  end
end
