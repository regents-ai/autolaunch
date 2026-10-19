defmodule AutolaunchWeb.MarketPageTest do
  @moduledoc """
  An auction or token page whose record cannot be read never answers that
  nothing lives there, which would tell people and search engines the page is
  gone. Only a lost database connection is the page that offers to try again
  (503); any other failed read is the plain error page (500), and the log names
  only the error's kind and module, never its text.

  A lost connection is made by cutting the case's own database connection
  (`pg_terminate_backend`, from a second connection) as the page's read of the
  auction starts. Another failure is made by renaming the table the read needs,
  inside the case's own transaction.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults
  import ExUnit.CaptureLog

  alias Autolaunch.{Auction, Repo, TestSupport}
  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  test "MARKET_PAGE_OUTAGE_ONLY_FOR_A_LOST_CONNECTION: a lost connection is a 503 with Try again",
       %{conn: conn} do
    auction = listed_auction("CUT")
    cut_when([:ash, :autolaunch, :read, :start], &(&1.resource == Auction))

    {{503, _headers, body}, log} =
      with_log(fn -> assert_error_sent(503, fn -> get(conn, Paths.auction(auction)) end) end)

    assert body =~ "Try again"
    assert log =~ "market page read connection_lost: "
  end

  test "MARKET_PAGE_OTHER_FAILURE_IS_A_500: a read that fails another way is the plain error page",
       %{conn: conn} do
    auction = listed_auction("UNREAD")

    # Lasts only as long as this case's sandboxed transaction: the read fails
    # with 42P01 (undefined_table), not a lost connection.
    Repo.query!("ALTER TABLE autolaunch_app.auctions RENAME TO auctions_unreadable")

    {{500, _headers, body}, log} =
      with_log(fn -> assert_error_sent(500, fn -> get(conn, Paths.auction(auction)) end) end)

    assert body =~ "Something went wrong"
    refute body =~ "Try again"
    # The log names the kind and what failed, as Ash hands it over, and none
    # of the database's message.
    assert log =~ "market page read failed: Ash.Error.Unknown.UnknownError"
    refute log =~ "auctions_unreadable"
    refute log =~ "42P01"
  end

  test "a token page whose token cannot be read is the plain error page, not a 404 or a 503",
       %{conn: conn} do
    auction = listed_auction("TOKUNREAD")

    TestSupport.project_token(
      auction_id: auction.id,
      symbol: "TOKUNREAD",
      graduated_at: DateTime.utc_now()
    )

    # The auction is found; the read of the token it launched fails.
    Repo.query!("ALTER TABLE autolaunch_app.tokens RENAME TO tokens_unreadable")

    {{500, _headers, body}, log} =
      with_log(fn -> assert_error_sent(500, fn -> get(conn, Paths.token(auction)) end) end)

    assert body =~ "Something went wrong"
    assert log =~ "market page read failed: "
    refute log =~ "tokens_unreadable"
  end

  test "an address that cannot name an auction is the not-found page", %{conn: conn} do
    {404, _headers, _body} = assert_error_sent(404, fn -> get(conn, "/tokens/NOPE/zzzzz") end)
    {404, _headers, _body} = assert_error_sent(404, fn -> get(conn, "/auctions/NOPE/zzzzz") end)
  end

  defp listed_auction(symbol) do
    stored = TestSupport.project_auction(chain_id: 8453, symbol: symbol)
    {:ok, auction} = Paths.find_auction(symbol, String.slice(stored.auction_address, -5, 5))
    auction
  end
end
