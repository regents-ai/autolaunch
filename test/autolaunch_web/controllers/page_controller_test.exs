defmodule AutolaunchWeb.PageControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  test "root serves the command-first homepage", %{conn: conn} do
    conn = get(conn, "/")

    html = html_response(conn, 200)

    assert html =~ "Copy the wizard command. Start the launch from one clear place."
    assert html =~ "Open operator path"
  end
end
