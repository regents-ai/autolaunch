defmodule AutolaunchWeb.TokenLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Repo
  alias Autolaunch.TestSupport

  test "token detail keeps its identifier and an honest not-found state", %{conn: conn} do
    for id <- ["token-42", Ecto.UUID.generate()] do
      {:ok, view, _html} = live(conn, "/tokens/#{id}")
      html = render_async(view)

      assert has_element?(view, "#autolaunch-token-detail")
      assert html =~ "Token not found"
      assert html =~ "No public token exists at #{id}."
      assert html =~ ~s(href="/tokens")
      refute html =~ "Retry"
    end
  end

  @tag :capture_log
  test "an unavailable token read offers Retry instead of not found, then recovers", %{
    conn: conn
  } do
    auction =
      TestSupport.project_auction(
        title: "Recovering token launch",
        summary: "Back after the outage.",
        symbol: "RCV",
        state: :graduated
      )

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        name: "Recovering Token",
        symbol: "RCV",
        subject_id: "subject:recovering-token-detail",
        graduated_at: DateTime.utc_now()
      )

    # The sandbox savepoints each statement, so renaming the table inside the test
    # transaction is a real failed read that the test can undo.
    Repo.query!("ALTER TABLE tokens RENAME TO tokens_unavailable")
    {:ok, view, _html} = live(conn, "/tokens/#{token.id}")
    html = render_async(view, 5_000)

    assert has_element?(view, "#autolaunch-token-detail[role=alert]", "Token unavailable")
    assert html =~ "This token could not be loaded right now."
    refute html =~ "not found"
    refute html =~ "Recovering token launch"
    refute html =~ "Postgrex"
    refute html =~ "undefined_table"

    retry = element(view, "#autolaunch-token-detail button", "Retry")
    assert render_click(retry) =~ "Loading…"
    assert render_async(view, 5_000) =~ "Token unavailable"

    Repo.query!("ALTER TABLE tokens_unavailable RENAME TO tokens")
    render_click(element(view, "#autolaunch-token-detail button", "Retry"))
    html = render_async(view, 5_000)

    assert html =~ "Recovering token launch · RCV"
    assert html =~ "Back after the outage."
    refute html =~ "Token unavailable"
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

  test "a listed token detail shows verified profile and company X", %{conn: conn} do
    account = TestSupport.register_creator!()

    auction =
      TestSupport.project_auction(
        title: "Linked token",
        summary: "A public research launch.",
        symbol: "LNK",
        state: :graduated,
        creator_human_account_id: account.id
      )

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        name: "Linked Token",
        symbol: "LNK",
        subject_id: "subject:linked-token-detail",
        graduated_at: DateTime.utc_now()
      )

    TestSupport.verify_x!(account, :profile, username: "alice")
    TestSupport.verify_x!(account, :company, username: "alicedao")

    {:ok, view, _html} = live(conn, "/tokens/#{token.id}")
    html = render_async(view)

    assert html =~ "@alice"
    assert html =~ "@alicedao"
    assert html =~ ~s(href="https://x.com/alice")
    assert html =~ ~s(href="https://x.com/alicedao")
  end
end
