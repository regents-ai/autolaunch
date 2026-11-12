defmodule AutolaunchWeb.ShareCardFailuresTest do
  @moduledoc """
  A launch's share picture that cannot be drawn answers the site's try-again
  page (503), as a market's picture does, so a site that shows the picture
  asks for it again.

  The failed drawing is made by renaming the table the picture's price line is
  read from, inside the case's own transaction.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{Repo, TestSupport}
  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  test "an auction's picture that cannot be drawn is the try-again page", %{conn: conn} do
    stored = TestSupport.project_auction(chain_id: 8453, symbol: "UNDRAWN", state: :active)
    {:ok, auction} = Paths.find_auction("UNDRAWN", String.slice(stored.auction_address, -5, 5))
    path = URI.parse(Paths.auction_image_url(auction, "1")).path

    Repo.query!(
      "ALTER TABLE autolaunch_app.auction_price_points RENAME TO auction_price_points_unreadable"
    )

    {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
    assert body =~ "Try again"
  end
end
