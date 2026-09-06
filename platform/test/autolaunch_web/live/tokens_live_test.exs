defmodule AutolaunchWeb.TokensLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  test "the empty tokens index keeps its identifier and copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tokens")
    html = render_async(view, 5_000)

    assert has_element?(view, "#autolaunch-tokens")
    assert html =~ "Tokens"
    assert html =~ "No tokens yet"
    assert html =~ "Tokens appear here after their auction graduates."
    assert html =~ ~s(href="/auctions")
  end

  test "the listed tokens index uses auction presentation and hides a nil-creator row", %{
    conn: conn
  } do
    hidden_id = TestSupport.insert_null_creator_auction!()

    visible =
      TestSupport.project_auction(title: "BixBench launch", symbol: "BIX", state: :graduated)

    graduated_at = DateTime.utc_now()

    hidden_token =
      TestSupport.project_token(
        auction_id: hidden_id,
        name: "Hidden Token",
        symbol: "HID",
        subject_id: "subject:hidden-token",
        graduated_at: graduated_at
      )

    visible_token =
      TestSupport.project_token(
        auction_id: visible.id,
        name: "Bix Token",
        symbol: "BIX",
        subject_id: "subject:visible-token",
        summary: "Graduated from BixBench launch.",
        graduated_at: graduated_at
      )

    {:ok, view, _html} = live(conn, ~p"/tokens")
    html = render_async(view, 5_000)

    assert has_element?(view, "#autolaunch-tokens")
    assert html =~ "BixBench launch"
    assert html =~ "BIX"
    assert html =~ ~s(href="/tokens/#{visible_token.id}")
    refute html =~ "Bix Token"
    refute html =~ hidden_token.id
    refute html =~ "Hidden Token"
  end

  test "verified profile and company X appear on the tokens index", %{conn: conn} do
    account = TestSupport.register_creator!()

    auction =
      TestSupport.project_auction(
        title: "Linked token",
        symbol: "LNK",
        state: :graduated,
        creator_human_account_id: account.id
      )

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        name: "Linked Token",
        symbol: "LNK",
        subject_id: "subject:linked-token",
        graduated_at: DateTime.utc_now()
      )

    TestSupport.verify_x!(account, :profile, username: "alice")
    TestSupport.verify_x!(account, :company, username: "alicedao")

    {:ok, view, _html} = live(conn, ~p"/tokens")
    html = render_async(view, 5_000)

    assert html =~ ~s(href="/tokens/#{token.id}")
    assert html =~ "@alice"
    assert html =~ "@alicedao"
    assert html =~ ~s(href="https://x.com/alice")
    assert html =~ ~s(href="https://x.com/alicedao")
  end
end
