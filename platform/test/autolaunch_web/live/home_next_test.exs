defmodule AutolaunchWeb.HomeNextTest do
  @moduledoc """
  Under the home page's list, what a visitor can join next: the auctions
  taking bids or opening soon, and only those. The tools agents see open from the footer and the developer guide,
  not from the top of every page.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.TestSupport

  test "Coming next names the auctions open now, the soonest first", %{conn: conn} do
    TestSupport.project_auction(chain_id: 8453, title: "Done Before", state: :graduated)
    TestSupport.project_auction(chain_id: 8453, title: "Taking Bids", state: :active)

    {:ok, view, _html} = live(conn, "/")
    coming = view |> element("section.home-next") |> render()

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

  test "a card that drops out of Coming next stays, hidden, until the list next changes",
       %{conn: conn} do
    leaving = TestSupport.project_auction(chain_id: 8453, title: "Leaving", state: :active)
    staying = TestSupport.project_auction(chain_id: 8453, title: "Staying", state: :active)
    {:ok, view, _html} = live(conn, "/")
    render_async(view)

    Autolaunch.hide_auction!(leaving, actor: %Autolaunch.Actors.System{})
    send(view.pid, :reread_listings)
    render_async(view)

    assert has_element?(view, "#home-next-card-#{leaving.id}[data-gone]")
    refute has_element?(view, "#home-next-card-#{staying.id}[data-gone]")

    send(view.pid, :reread_listings)
    render_async(view)
    assert has_element?(view, "#home-next-card-#{leaving.id}[data-gone]")

    arriving = TestSupport.project_auction(chain_id: 8453, title: "Arriving", state: :active)
    send(view.pid, :reread_listings)
    render_async(view)

    refute has_element?(view, "#home-next-card-#{leaving.id}")
    assert has_element?(view, "#home-next-card-#{staying.id}")
    assert has_element?(view, "#home-next-card-#{arriving.id}")
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
