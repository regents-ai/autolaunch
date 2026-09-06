defmodule AutolaunchWeb.AuctionLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  test "auction detail keeps its identifier and an honest not-found state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/auctions/auction-42")
    html = render_async(view, 5_000)

    assert has_element?(view, "#autolaunch-auction-detail")
    assert html =~ "Auction not found"
    assert html =~ "No public auction exists"
    assert html =~ ~s(href="/auctions")
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
