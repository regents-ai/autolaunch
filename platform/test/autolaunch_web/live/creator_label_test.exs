defmodule AutolaunchWeb.CreatorLabelTest do
  @moduledoc """
  A launch's creator is named the same way on every list row and page: by the
  first account the auction page shows as ownership checked, else by the
  launching wallet, shortened.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.TestSupport
  alias AutolaunchWeb.Paths

  test "a creator with a checked X account is named by it in the list and on both pages",
       %{conn: conn} do
    creator = TestSupport.register_creator!()
    TestSupport.verify_x!(creator, :profile, username: "launchmaker")

    stored =
      TestSupport.project_auction(
        chain_id: 8453,
        symbol: "NAMED",
        state: :graduated,
        creator_human_account_id: creator.id,
        token_address: "0x3333333333333333333333333333333333333333"
      )

    {:ok, auction} = Paths.find_auction("NAMED", String.slice(stored.auction_address, -5, 5))
    TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    {:ok, list, _html} = live(conn, "/auctions")
    assert render_async(list) =~ ~r/by @launchmaker/

    {:ok, tokens, _html} = live(conn, "/tokens")
    assert render_async(tokens) =~ ~r/by @launchmaker/

    for page <- [Paths.auction(auction), Paths.token(auction)] do
      {:ok, view, _html} = live(conn, page)
      # The page also tries the chain, which this test does not run.
      html = render_async(view, 5_000)
      assert html =~ "launchmaker"
      refute html =~ ~r/by\s*<a[^>]*>\s*#{RegentFormat.short_address(stored.creator_address)}/
    end
  end

  test "a creator with no checked account is named by the short launching wallet",
       %{conn: conn} do
    stored = TestSupport.project_auction(chain_id: 8453, symbol: "WALLET", state: :graduated)
    short = RegentFormat.short_address(stored.creator_address)

    {:ok, list, _html} = live(conn, "/auctions")
    assert render_async(list) =~ "by #{short}"

    {:ok, auction} = Paths.find_auction("WALLET", String.slice(stored.auction_address, -5, 5))
    {:ok, view, _html} = live(conn, Paths.auction(auction))
    html = render_async(view, 5_000)
    assert html =~ short
    refute html =~ ~r/by\s*<a[^>]*>\s*#{stored.creator_address}/
  end
end
