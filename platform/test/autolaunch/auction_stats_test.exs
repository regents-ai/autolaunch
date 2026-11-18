defmodule Autolaunch.AuctionStatsTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.{AuctionStats, RobinhoodBidChain, TestSupport}

  test "an auction an operator hid is in no count, as it is in no list" do
    for state <- [:active, :active, :graduated, :graduated],
        do: TestSupport.project_auction(chain_id: 8453, state: state)

    hidden_live = TestSupport.project_auction(chain_id: 8453, state: :active)
    hidden_graduated = TestSupport.project_auction(chain_id: 8453, state: :graduated)

    assert {:ok, %{live: 3, graduated: 3}} = AuctionStats.revstake()

    {:ok, _hidden} = Autolaunch.hide_auction(hidden_live, actor: %System{})
    {:ok, _hidden} = Autolaunch.hide_auction(hidden_graduated, actor: %System{})

    assert {:ok, %{live: 2, graduated: 2}} = AuctionStats.revstake()
  end

  test "an operator hides a Robinhood auction and puts it back: it leaves the Robinhood count and returns to it" do
    RobinhoodBidChain.install()

    auction =
      TestSupport.project_auction(
        chain_id: RobinhoodBidChain.chain_id(),
        kind: :stocks,
        state: :active
      )

    assert {:ok, %{memestock: %{robinhood: %{live: 1}}}} = AuctionStats.by_chain()

    {:ok, hidden} = Autolaunch.hide_auction(auction, actor: %System{})
    assert {:ok, %{memestock: %{robinhood: %{live: 0}}}} = AuctionStats.by_chain()

    {:ok, _shown} = Autolaunch.show_auction(hidden, actor: %System{})
    assert {:ok, %{memestock: %{robinhood: %{live: 1}}}} = AuctionStats.by_chain()
  end
end
