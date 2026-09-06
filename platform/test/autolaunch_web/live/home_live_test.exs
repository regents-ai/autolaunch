defmodule AutolaunchWeb.HomeLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport
  alias AutolaunchWeb.Components.TokenLinks

  test "the empty home keeps the explore title, chips, and empty copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = render_async(view)

    assert has_element?(view, "#home-explore-title", "Explore coins")
    assert has_element?(view, ~s(a[href="/create"]), "Create")
    assert_regent_market_links(html)

    assert has_element?(
             view,
             ~s(nav[aria-label="Market filters"] a[aria-current="true"]),
             "Active"
           )

    assert html =~ "Active"
    assert html =~ "New"
    assert html =~ "Tokens"
    refute html =~ "Ending soon"
    assert has_element?(view, "#home-market", "No auctions yet.")
    refute html =~ "Create an auction"
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

    {:ok, view, _html} = live(conn, "/?view=tokens")
    html = render_async(view)

    assert html =~ "BixBench token"
    assert html =~ ~s(href="/tokens/#{token.id}")
    assert html =~ "No price yet"
    refute html =~ "market cap"
  end

  test "verified profile and company X appear on home cards", %{conn: conn} do
    account = TestSupport.register_creator!()

    TestSupport.project_auction(
      title: "Linked launch",
      state: :active,
      creator_human_account_id: account.id
    )

    TestSupport.verify_x!(account, :profile, username: "alice")
    TestSupport.verify_x!(account, :company, username: "alicedao")

    {:ok, view, _html} = live(conn, "/")
    html = render_async(view)

    assert html =~ "Linked launch"
    assert html =~ "@alice"
    assert html =~ "@alicedao"
    assert html =~ ~s(href="https://x.com/alice")
    assert html =~ ~s(href="https://x.com/alicedao")
    assert html =~ "Creator"
    assert html =~ "Company"
  end

  test "verified X follows a graduated token onto the home Tokens chip", %{conn: conn} do
    account = TestSupport.register_creator!()

    auction =
      TestSupport.project_auction(
        title: "Linked token",
        symbol: "LNK",
        state: :graduated,
        creator_human_account_id: account.id
      )

    TestSupport.project_token(
      auction_id: auction.id,
      name: "Linked Token",
      symbol: "LNK",
      subject_id: "subject:home-linked-token",
      graduated_at: DateTime.utc_now()
    )

    TestSupport.verify_x!(account, :profile, username: "alice")
    TestSupport.verify_x!(account, :company, username: "alicedao")

    {:ok, view, _html} = live(conn, "/?view=tokens")
    html = render_async(view)

    assert html =~ "Linked token"
    assert html =~ "@alice"
    assert html =~ "@alicedao"
    assert html =~ ~s(href="https://x.com/alice")
    assert html =~ ~s(href="https://x.com/alicedao")
  end

  defp assert_regent_market_links(html) do
    assert html =~ ~s(id="regent-buy")
    assert html =~ ~s(href="#{TokenLinks.buy()}")
    assert html =~ "Buy REGENT"
    assert html =~ ~s(id="regent-chart")
    assert html =~ ~s(href="#{TokenLinks.chart()}")
    assert html =~ "View REGENT Chart"
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
  end
end
