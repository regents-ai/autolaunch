defmodule AutolaunchWeb.HomeNextTest do
  @moduledoc """
  The home page says what Autolaunch is and offers two ways in, then what a
  visitor can join next: the auctions taking bids or opening soon, or, while
  there are none, stocks ready to launch with and the latest results. The
  tools agents see open from the footer and the developer guide, not from
  the top of every page.
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

  test "with nothing open, Coming next offers stocks to launch with and the latest results",
       %{conn: conn} do
    TestSupport.project_auction(chain_id: 8453, title: "Done Before", state: :graduated)

    {:ok, view, _html} = live(conn, "/")
    coming = view |> element("section.home-next") |> render()

    assert coming =~ "Done Before"
    assert coming =~ ~s(href="/stock-listing/)
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
