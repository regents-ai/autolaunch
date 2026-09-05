defmodule AutolaunchWeb.HealthControllerTest do
  use AutolaunchWeb.ConnCase, async: true

  test "GET /healthz answers with plain text ok", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert conn.resp_body == "ok"
  end
end
