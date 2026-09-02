defmodule AutolaunchWeb.HomeLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  test "the public root answers an anonymous visitor and mounts", %{conn: conn} do
    assert html_response(get(conn, "/"), 200) =~ "Autolaunch"

    assert {:ok, view, html} = live(conn, "/")
    assert html =~ "Autolaunch"
    assert render(view) =~ "Autolaunch"
  end
end
