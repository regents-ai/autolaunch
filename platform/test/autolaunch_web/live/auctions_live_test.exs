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
end
