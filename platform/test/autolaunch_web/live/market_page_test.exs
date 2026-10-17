defmodule AutolaunchWeb.MarketPageTest do
  @moduledoc """
  An auction or token page whose record cannot be read answers that it could
  not open and offers to try again. It never answers that nothing lives there,
  which would tell people and search engines the page is gone.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{Repo, TestSupport}
  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  test "an auction page whose auction cannot be read is a 503 with Try again, not a 404",
       %{conn: conn} do
    stored = TestSupport.project_auction(chain_id: 8453, symbol: "UNREAD")
    {:ok, auction} = Paths.find_auction("UNREAD", String.slice(stored.auction_address, -5, 5))

    # Lasts only as long as this case's sandboxed transaction.
    Repo.query!("ALTER TABLE autolaunch_app.auctions RENAME TO auctions_unreadable")

    {503, _headers, body} = assert_error_sent(503, fn -> get(conn, Paths.auction(auction)) end)
    assert body =~ "Try again"
  end
end
