defmodule AutolaunchWeb.PageControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  test "root serves the command-first homepage", %{conn: conn} do
    conn = get(conn, "/")

    html = html_response(conn, 200)

    assert html =~ "Start the wizard. Let OpenClaw or Hermes carry the launch."
    assert html =~ "Copy OpenClaw brief"
  end
end
