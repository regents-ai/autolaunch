defmodule AutolaunchWeb.HomeNextTest do
  @moduledoc """
  The home page says what Autolaunch is and offers two ways in, then what a
  visitor can join next: the auctions taking bids or opening soon, and only
  those. The tools agents see open from the footer and the developer guide,
  not from the top of every page.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.TestSupport

  test "Coming next names the auctions open now, the soonest first", %{conn: conn} do
    TestSupport.project_auction(chain_id: 8453, title: "Done Before", state: :graduated)
    TestSupport.project_auction(chain_id: 8453, title: "Taking Bids", state: :active)

    {:ok, view, html} = live(conn, "/")
    coming = view |> element("section.home-next") |> render()

    assert html =~ "Back a launch"
    assert html =~ "Launch yours"
    assert coming =~ "Taking Bids"
    refute coming =~ "Done Before"
  end

  test "with nothing open, Coming next says so and the finished auction stays in the list",
       %{conn: conn} do
    TestSupport.project_auction(chain_id: 8453, title: "Done Before", state: :graduated)

    {:ok, view, _html} = live(conn, "/")
    coming = view |> element("section.home-next") |> render()

    assert has_element?(view, "section.home-next .home-next__empty")
    refute coming =~ "Done Before"
    assert view |> element("#home-market") |> render() =~ "Done Before"
  end

  test "Clear search drops only the search and keeps the other filters", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?q=frog&chain=base")

    view |> element(".home-search-context button", "Clear search") |> render_click()

    assert_patch(view, "/?chain=base")
    assert has_element?(view, ".home-search-context[hidden]")
  end

  test "the tools agents see open from the footer and the developer guide", %{conn: conn} do
    home = conn |> get("/") |> html_response(200)
    docs = conn |> get("/docs") |> html_response(200)

    [before_footer, footer] = String.split(home, ~s(id="shell-footer"), parts: 2)
    refute before_footer =~ "data-agent-tools-open"
    assert footer =~ "data-agent-tools-open"
    assert docs =~ ~s(id="docs-agent-tools-button")
  end
end
