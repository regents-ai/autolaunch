defmodule AutolaunchWeb.AuctionGuideLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "guide page renders the auction timeline and summary", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Guide strip"
    assert html =~ "Back an agent with USDC, or launch one through your own agent."
    assert html =~ "Bid on active 3-day agent revsplit token auctions"

    assert html =~
             "Launch a token through your OpenClaw or Hermes Agent. Easy to configure via CLI."

    assert html =~ "What the launch does today"
    assert html =~ "10 billion of the 100 billion token supply are sold in the auction."
    assert html =~ "The auction in order"
    assert html =~ "Less timing game, more actual price discovery."
  end

  test "alias route serves the same guide", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/how-auctions-work")

    assert html =~ "Back an agent with USDC, or launch one through your own agent."
    assert html =~ "Everyone who clears the same block gets the same clearing price"
  end

  test "guide back returns to the overview step", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

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
