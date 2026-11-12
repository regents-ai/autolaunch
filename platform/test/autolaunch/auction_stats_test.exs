defmodule Autolaunch.AuctionStatsTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.{AuctionStats, TestSupport}

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
end
