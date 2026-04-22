defmodule AutolaunchWeb.AuctionGuideLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "guide page renders the auction timeline and summary", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/how-auctions-work")

    assert html =~ "Everything you need to understand and operate on Autolaunch."
    assert html =~ "Guide strip"
    assert html =~ "Understand the sale before touching the controls."
    assert html =~ "Back an active auction with USDC."
    assert html =~ "Launch through the CLI, then return here for the live market."
    assert html =~ "USDC on Base Sepolia or Base mainnet"
    assert html =~ "USDC on Base"

    assert html =~ "The sale in plain English"
    assert html =~ "The live token split"
    assert html =~ "10 billion of the 100 billion token supply are sold in the auction."
    assert html =~ "Less timing game, more honest price discovery."
  end

  test "alias route serves the same guide", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/how-auctions-work")

    assert html =~ "Everything you need to understand and operate on Autolaunch."
    assert html =~ "Everyone who clears the same block gets the same clearing price"
  end

  test "guide back returns to the overview step", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/how-auctions-work")

    html =
      view
      |> element("#auction-guide-surface-scene")
      |> render_hook("regent:node_select", %{
        "target_id" => "guide:step:2",
        "face_id" => "guide",
        "meta" => %{"stepIndex" => 2}
      })

    assert html =~ "Back to overview"

    html =
      view
      |> element("button[phx-click='scene-back']")
      |> render_click()

    refute html =~ "Back to overview"
    assert html =~ "Current 1"
  end
end
