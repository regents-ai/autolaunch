defmodule AutolaunchWeb.PageControllerTest do
  use AutolaunchWeb.ConnCase, async: true

  test "GET / renders the home page", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ "Autolaunch"
  end
end
