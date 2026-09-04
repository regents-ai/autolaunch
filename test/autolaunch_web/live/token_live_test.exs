defmodule AutolaunchWeb.TokenLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  test "token detail keeps its identifier and an honest not-found state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tokens/token-42")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-token-detail")
    assert html =~ "Token not found"
    assert html =~ "No public token exists"
    assert html =~ ~s(href="/tokens")
  end

  test "a listed token detail uses auction presentation and hides a nil-creator row", %{
    conn: conn
  } do
    hidden_id = TestSupport.insert_null_creator_auction!()

    visible =
      TestSupport.project_auction(
        title: "BixBench launch",
        summary: "A public research launch.",
        symbol: "BIX",
        state: :graduated
      )

    graduated_at = DateTime.utc_now()

    hidden_token =
      TestSupport.project_token(
        auction_id: hidden_id,
        name: "Hidden Token",
        symbol: "HID",
        subject_id: "subject:hidden-token-detail",
        graduated_at: graduated_at
      )

    visible_token =
      TestSupport.project_token(
        auction_id: visible.id,
        name: "Bix Token",
        symbol: "BIX",
        subject_id: "subject:visible-token-detail",
        summary: "Graduated from BixBench launch.",
        graduated_at: graduated_at
      )

    {:ok, view, _html} = live(conn, "/tokens/#{visible_token.id}")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-token-detail")
    assert html =~ "BixBench launch · BIX"
    assert html =~ "A public research launch."
    refute html =~ "Graduated from BixBench launch."
    refute html =~ "Bix Token"

    {:ok, hidden_view, _html} = live(conn, "/tokens/#{hidden_token.id}")
    hidden_html = render_async(hidden_view)

    assert has_element?(hidden_view, "#autolaunch-token-detail", "Token not found")
    refute hidden_html =~ "Hidden Token"
  end
end
