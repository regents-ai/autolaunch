defmodule AutolaunchWeb.RobinhoodPagesLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:autolaunch, :autolaunch_robinhood_deployment)
    Application.put_env(:autolaunch, :autolaunch_robinhood_deployment, "robinhood.json")

    on_exit(fn ->
      Application.put_env(:autolaunch, :autolaunch_robinhood_deployment, previous)
    end)
  end

  # A page opened on something that is not an address has nothing to read
  # again, so a later feed update leaves it standing.
  for path <- ["/robinhood/auctions/not-an-address", "/robinhood/tokens/not-an-address"] do
    test "#{path} outlives a Robinhood feed update", %{conn: conn} do
      {:ok, view, _html} = live(conn, unquote(path))

      send(view.pid, {:robinhood_market_updated, %{}})

      assert render(view) =~ "not found"
    end
  end

  # Every page that shows live figures hears both networks' feeds, so a Base
  # page must outlive a Robinhood update too.
  for path <- ["/tokens/7d1b3c9e-2f4a-4c5d-9e8f-0a1b2c3d4e5f", "/portfolio"] do
    test "#{path} outlives a Robinhood feed update", %{conn: conn} do
      {:ok, view, _html} = live(conn, unquote(path))

      send(view.pid, {:robinhood_market_updated, %{}})

      assert render(view)
    end
  end
end
