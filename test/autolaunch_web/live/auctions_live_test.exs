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
end
