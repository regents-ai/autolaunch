defmodule AutolaunchWeb.AuctionsLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  test "the empty auctions index keeps its identifier and copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/auctions")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-auctions")
    assert html =~ "Auctions"
    assert html =~ "No auctions yet"
    assert html =~ "Start the first launch and it will appear here for bidders."
    assert html =~ ~s(href="/create")
    assert html =~ ~s(id="regent-buy")
    assert html =~ ~s(href="#{AutolaunchWeb.Components.TokenLinks.buy()}")
    assert html =~ "Buy REGENT"
    assert html =~ ~s(id="regent-chart")
    assert html =~ ~s(href="#{AutolaunchWeb.Components.TokenLinks.chart()}")
    assert html =~ "View REGENT Chart"
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
  end

  test "the listed auctions index shows a site-created row and hides a nil-creator row", %{
    conn: conn
  } do
    hidden_id = TestSupport.insert_null_creator_auction!()
    visible = TestSupport.project_auction(title: "BixBench launch", state: :active)

    {:ok, view, _html} = live(conn, ~p"/auctions")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-auctions")
    assert html =~ "BixBench launch"
    assert html =~ ~s(href="/auctions/#{visible.id}")
    refute html =~ hidden_id
    refute html =~ "Hidden"
  end

  test "verified profile and company X appear on the auctions index", %{conn: conn} do
    account = TestSupport.register_creator!()

    TestSupport.project_auction(
      title: "Linked launch",
      state: :active,
      creator_human_account_id: account.id
    )

    TestSupport.verify_x!(account, :profile, username: "alice")
    TestSupport.verify_x!(account, :company, username: "alicedao")

    {:ok, view, _html} = live(conn, ~p"/auctions")
    html = render_async(view)

    assert html =~ "Linked launch"
    assert html =~ "@alice"
    assert html =~ "@alicedao"
    assert html =~ ~s(href="https://x.com/alice")
    assert html =~ ~s(href="https://x.com/alicedao")
  end

  test "browse continuation and expired-link recovery", %{conn: conn} do
    for n <- 1..27, do: TestSupport.project_auction(title: "Browse #{n}", state: :active)
    {:ok, view, _} = live(conn, "/auctions")
    render_async(view)

    assert Enum.count(
             view
             |> element(".home-coin-grid")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".launchpad-card")
           ) == 24

    view |> element("nav[aria-label='Browse pages'] a", "Next page") |> render_click()
    render_async(view)

    assert Enum.count(
             view
             |> element(".home-coin-grid")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".launchpad-card")
           ) == 3

    assert has_element?(view, "a", "Back to newest")
    refute has_element?(view, "nav a", "Next page")
    render_patch(view, "/auctions?after=invalid")
    render_async(view)
    assert render(view) =~ "expired or is invalid"
    refute has_element?(view, ".home-coin-grid")
    view |> element("a", "Back to newest") |> render_click()
    render_async(view)
    assert has_element?(view, ".home-coin-grid")
  end
end
