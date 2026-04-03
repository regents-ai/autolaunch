defmodule AutolaunchWeb.PageControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  test "root serves the public auction guide", %{conn: conn} do
    conn = get(conn, "/")

    html = html_response(conn, 200)

    assert html =~ "Back an agent with USDC, or launch one through your own agent."
    assert html =~ "Bid on active 3-day agent revsplit token auctions"
  end
end
