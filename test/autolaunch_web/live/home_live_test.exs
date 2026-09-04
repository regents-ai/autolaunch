defmodule AutolaunchWeb.HomeLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  test "the empty home keeps the create panel, chips, and section copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view)

    assert has_element?(view, "#home-create-title", "Create an auction")
    assert has_element?(view, ~s(a[href="/create"]), "Create an auction")

    assert has_element?(
             view,
             ~s(nav[aria-label="Market filters"] a[aria-current="true"]),
             "Active"
           )

    assert html =~ "Active"
    assert html =~ "New"
    refute html =~ "Ending soon"
    assert has_element?(view, "#home-auctions", "No auctions yet.")
    assert has_element?(view, "#home-tokens", "No tokens yet.")
  end

  test "a projected auction appears on home", %{conn: conn} do
    auction = TestSupport.project_auction(title: "BixBench launch", state: :active)

    {:ok, view, _html} = live(conn, "/")
    html = render_async(view)

    assert html =~ "BixBench launch"
    assert html =~ ~s(href="/auctions/#{auction.id}")
    refute html =~ "No auctions yet."
  end

  test "search q filters auctions through the launchpad reads", %{conn: conn} do
    TestSupport.project_auction(title: "BixBench launch", state: :active)

    {:ok, match_view, _html} = live(conn, "/?q=BixBench")
    match_html = render_async(match_view)

    assert match_html =~ "BixBench launch"

    {:ok, miss_view, _html} = live(conn, "/?q=zzzz-nomatch")
    miss_html = render_async(miss_view)

    refute miss_html =~ "BixBench launch"
    assert miss_html =~ "No matching auctions or tokens."
  end

  test "a graduated token card states when no price is recorded", %{conn: conn} do
    auction =
      TestSupport.project_auction(title: "BixBench token", symbol: "BIX", state: :graduated)

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        name: "Bix Token",
        symbol: "BIX",
        subject_id: "subject:home-token",
        graduated_at: DateTime.utc_now()
      )

    {:ok, view, _html} = live(conn, "/")
    html = render_async(view)

    assert html =~ "BixBench token"
    assert html =~ ~s(href="/tokens/#{token.id}")
    assert html =~ "No price yet"
    refute html =~ "market cap"
  end
end
