defmodule AutolaunchWeb.OldLinkControllerTest do
  @moduledoc """
  An old link whose read fails never answers that nothing lives there: it
  answers as a market page does, the try-again page (503) only for a lost
  database connection and the plain error page (500) for anything else.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults
  import ExUnit.CaptureLog

  alias Autolaunch.{Auction, Repo, TestSupport}
  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  test "OLD_LINK_FAILED_READ_IS_NOT_A_MISSING_PAGE: a read that fails is a 500, never a 404",
       %{conn: conn} do
    auction = listed_auction("OLDLINK")
    token = TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    # While the reads work, an old link moves to the page and one to nothing is
    # the not-found page.
    assert redirected_to(get(conn, "/auctions/#{auction.id}"), 301) == Paths.auction(auction)
    assert redirected_to(get(conn, "/tokens/#{token.id}"), 301) == Paths.token(auction)

    {404, _headers, _body} =
      assert_error_sent(404, fn -> get(conn, "/auctions/#{Ecto.UUID.generate()}") end)

    # Lasts only as long as this case's sandboxed transaction: each read fails
    # with 42P01 (undefined_table), not a lost connection.
    Repo.query!("ALTER TABLE autolaunch_app.auctions RENAME TO auctions_unreadable")
    Repo.query!("ALTER TABLE autolaunch_app.tokens RENAME TO tokens_unreadable")

    for path <- [
          "/auctions/#{auction.id}",
          "/auctions/#{auction.id}/share.png",
          "/tokens/#{token.id}"
        ] do
      {{500, _headers, body}, log} =
        with_log(fn -> assert_error_sent(500, fn -> get(conn, path) end) end)

      assert body =~ "Something went wrong", path
      assert log =~ "old link read failed: Ash.Error.", path
      refute log =~ "_unreadable"
      refute log =~ "42P01"
    end
  end

  test "an old link that loses the database connection is a 503 with Try again", %{conn: conn} do
    auction = listed_auction("OLDCUT")
    cut_when([:ash, :autolaunch, :read, :start], &(&1.resource == Auction))

    {{503, _headers, body}, log} =
      with_log(fn -> assert_error_sent(503, fn -> get(conn, "/auctions/#{auction.id}") end) end)

    assert body =~ "Try again"
    assert log =~ "old link read connection_lost: "
  end

  defp listed_auction(symbol) do
    stored = TestSupport.project_auction(chain_id: 8453, symbol: symbol)
    {:ok, auction} = Paths.find_auction(symbol, String.slice(stored.auction_address, -5, 5))
    auction
  end
end
