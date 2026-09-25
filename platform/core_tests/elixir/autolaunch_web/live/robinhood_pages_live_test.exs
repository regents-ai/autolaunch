defmodule AutolaunchWeb.RobinhoodPagesLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport
  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:autolaunch, :autolaunch_robinhood_deployment)
    Application.put_env(:autolaunch, :autolaunch_robinhood_deployment, "robinhood.json")

    on_exit(fn ->
      Application.put_env(:autolaunch, :autolaunch_robinhood_deployment, previous)
    end)
  end

  # Every page that shows live figures hears both networks' feeds, so a Base
  # page must outlive a Robinhood update too.
  test "a Base token page outlives a Robinhood feed update", %{conn: conn} do
    stored = TestSupport.project_auction(chain_id: 8453, symbol: "BSPG", state: :graduated)
    {:ok, auction} = Paths.find_auction("BSPG", String.slice(stored.auction_address, -5, 5))

    TestSupport.project_token(
      auction_id: auction.id,
      symbol: "BSPG",
      graduated_at: DateTime.utc_now()
    )

    {:ok, view, _html} = live(conn, Paths.token(auction))

    send(view.pid, {:robinhood_market_updated, %{}})

    assert render(view)
  end

  test "/portfolio outlives a Robinhood feed update", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/portfolio")

    send(view.pid, {:robinhood_market_updated, %{}})

    assert render(view)
  end
end
