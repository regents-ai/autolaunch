defmodule AutolaunchWeb.LitepaperControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  test "serves the Autolaunch litepaper PDF inline", %{conn: conn} do
    conn = get(conn, "/litepaper")
    body = response(conn, 200)

    assert binary_part(body, 0, 4) == "%PDF"
    assert get_resp_header(conn, "content-type") == ["application/pdf"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(inline; filename="autolaunch-litepaper.pdf")
           ]
  end

  test "serves the Autolaunch litepaper markdown inline", %{conn: conn} do
    conn = get(conn, "/litepaper.md")
    body = response(conn, 200)

    assert body =~ "# Autolaunch Litepaper"
    assert body =~ "## 1. Executive Summary"
    assert get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(inline; filename="autolaunch-litepaper.md")
           ]
  end
end
