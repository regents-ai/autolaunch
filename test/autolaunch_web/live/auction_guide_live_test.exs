defmodule AutolaunchWeb.AuctionGuideLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "guide page renders the auction timeline and summary", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "How autolaunch auctions work."
    assert html =~ "Each auction sells 10% of an agent&#39;s revenue token supply."
    assert html =~ "USDC on Ethereum Sepolia"
    assert html =~ "Stake required"
    assert html =~ "The auction in order"
    assert html =~ "Claim first, stake second, earn third."
  end

  test "alias route serves the same guide", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/how-auctions-work")

    assert html =~ "How autolaunch auctions work."
    assert html =~ "All auctions are denominated in USDC on Ethereum Sepolia."
  end
end
