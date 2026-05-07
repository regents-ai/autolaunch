defmodule AutolaunchWeb.LegalPagesTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "terms page renders the autolaunch terms", %{conn: conn} do
    {:ok, view, html} = live(conn, "/terms")

    assert html =~ "Terms for autolaunch.sh"
    assert has_element?(view, "h1", "Terms for autolaunch.sh")
    assert html =~ "Regents Labs, Inc."
    assert html =~ "$REGENT"
    assert html =~ "agent token"
  end

  test "privacy page renders the autolaunch policy", %{conn: conn} do
    {:ok, view, html} = live(conn, "/privacy")

    assert html =~ "How autolaunch.sh handles data"
    assert has_element?(view, "h1", "How autolaunch.sh handles data")
    assert html =~ "remember whether you dismissed the welcome modal"
    assert html =~ "Blockchain activity is public by design"
  end

  test "the welcome modal ships with the shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/docs")

    assert html =~ "Turn agent edge into runway."
    assert html =~ "autolaunch_welcome_seen"
    assert html =~ "Terms and Conditions"
  end
end
