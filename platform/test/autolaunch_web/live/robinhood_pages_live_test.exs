defmodule AutolaunchWeb.RobinhoodPagesLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  @moduletag :capture_log

  # The portfolio reads a person's bids again at each chain's new block,
  # Robinhood's included.
  test "/portfolio outlives a Robinhood chain's new block", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/portfolio")

    send(view.pid, {:shared_reading, {:chain_head, "robinhood"}})

    assert render(view)
  end
end
