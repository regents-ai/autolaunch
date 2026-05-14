defmodule AutolaunchWeb.AuctionGuideLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "guide page renders the auction timeline and summary", %{conn: conn} do
    {:ok, view, html} = live(conn, "/docs")

    assert html =~ "Learn the Autolaunch market before you bid or launch."

    assert has_element?(
             view,
             "h1",
             "Learn the Autolaunch market before you bid or launch."
           )

    assert html =~ "Guide strip"
    assert html =~ "Understand the sale before you bid."
    assert html =~ "Back an active auction with USDC."
    assert html =~ "Launch through the CLI, then return here for the live market."
    assert html =~ "USDC on Base"
    assert html =~ "USDC on Base"
    refute html =~ "al-docs-masthead-illustration"
    refute html =~ "al-docs-masthead-book"

    assert html =~ "The sale in plain English"
    assert html =~ "The live token split"
    assert html =~ "10 billion of the 100 billion token supply are sold in the auction."
    assert html =~ "Less timing game, more honest price discovery."
  end

  test "docs route serves the auction guide", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/docs")

    assert html =~ "Learn the Autolaunch market before you bid or launch."
    assert html =~ "Buyers who clear together receive the same sale price"
  end

  test "guide back returns to the overview step", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/docs")

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
