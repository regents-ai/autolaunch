defmodule AutolaunchWeb.AuctionLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Repo
  alias Autolaunch.TestSupport

  test "auction detail keeps its identifier and an honest not-found state", %{conn: conn} do
    for id <- ["auction-42", Ecto.UUID.generate()] do
      {:ok, view, _html} = live(conn, "/auctions/#{id}")
      html = render_async(view, 5_000)

      assert has_element?(view, "#autolaunch-auction-detail")
      assert html =~ "Auction not found"
      assert html =~ "No public auction exists at #{id}."
      assert html =~ ~s(href="/auctions")
      refute html =~ "Retry"
    end
  end

  @tag :capture_log
  test "an unavailable auction read offers Retry instead of not found, then recovers", %{
    conn: conn
  } do
    auction =
      TestSupport.project_auction(
        title: "Recovering launch",
        summary: "Back after the outage.",
        symbol: "RCV",
        state: :active
      )

    # The sandbox savepoints each statement, so renaming the table inside the test
    # transaction is a real failed read that the test can undo.
    Repo.query!("ALTER TABLE auctions RENAME TO auctions_unavailable")
    {:ok, view, _html} = live(conn, "/auctions/#{auction.id}")
    html = render_async(view, 5_000)

    assert has_element?(view, "#autolaunch-auction-detail[role=alert]", "Auction unavailable")
    assert html =~ "This auction could not be loaded right now."
    refute html =~ "not found"
    refute html =~ "Recovering launch"
    refute html =~ "Postgrex"
    refute html =~ "undefined_table"

    retry = element(view, "#autolaunch-auction-detail button", "Retry")
    assert render_click(retry) =~ "Loading…"
    assert render_async(view, 5_000) =~ "Auction unavailable"

    Repo.query!("ALTER TABLE auctions_unavailable RENAME TO auctions")
    render_click(element(view, "#autolaunch-auction-detail button", "Retry"))
    html = render_async(view, 5_000)

    assert html =~ "Recovering launch"
    assert html =~ "Back after the outage."
    assert html =~ ~s(id="autolaunch-bid")
    refute html =~ "Auction unavailable"
  end

  test "moving to another auction never shows the previous record", %{conn: conn} do
    first = TestSupport.project_auction(title: "First launch", symbol: "ONE", state: :active)
    second = TestSupport.project_auction(title: "Second launch", symbol: "TWO", state: :active)

    {:ok, view, _html} = live(conn, "/auctions/#{first.id}")
    assert render_async(view, 5_000) =~ "First launch"

    patched = render_patch(view, "/auctions/#{second.id}")
    refute patched =~ "First launch"
    assert patched =~ "Loading…"

    html = render_async(view, 5_000)
    assert html =~ "Second launch"
    refute html =~ "First launch"
  end

  test "a listed auction detail shows the public record", %{conn: conn} do
    auction =
      TestSupport.project_auction(
        title: "BixBench launch",
        summary: "A public research launch.",
        symbol: "BIX",
        state: :active
      )

    {:ok, view, _html} = live(conn, "/auctions/#{auction.id}")
    html = render_async(view, 5_000)

    assert has_element?(view, "#autolaunch-auction-detail")
    assert html =~ "BixBench launch"
    assert html =~ "A public research launch."
    assert html =~ ~s(id="regent-buy")
    assert html =~ ~s(href="#{AutolaunchWeb.Components.TokenLinks.buy()}")
    assert html =~ "Buy REGENT"
    assert html =~ ~s(id="regent-chart")
    assert html =~ ~s(href="#{AutolaunchWeb.Components.TokenLinks.chart()}")
    assert html =~ "View REGENT Chart"
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
  end

  test "a listed auction detail shows verified profile and company X", %{conn: conn} do
    account = TestSupport.register_creator!()

    auction =
      TestSupport.project_auction(
        title: "Linked launch",
        summary: "A public research launch.",
        symbol: "LNK",
        state: :active,
        creator_human_account_id: account.id
      )

    TestSupport.verify_x!(account, :profile, username: "alice")
    TestSupport.verify_x!(account, :company, username: "alicedao")

    {:ok, view, _html} = live(conn, "/auctions/#{auction.id}")
    html = render_async(view, 5_000)

    assert html =~ "@alice"
    assert html =~ "@alicedao"
    assert html =~ ~s(href="https://x.com/alice")
    assert html =~ ~s(href="https://x.com/alicedao")
  end

  test "a nil-creator auction's detail route is not reachable", %{conn: conn} do
    hidden_id = TestSupport.insert_null_creator_auction!()

    {:ok, view, _html} = live(conn, "/auctions/#{hidden_id}")
    html = render_async(view, 5_000)

    assert has_element?(view, "#autolaunch-auction-detail", "Auction not found")
    assert html =~ "No public auction exists at #{hidden_id}."
    refute html =~ "Hidden"
  end
end
