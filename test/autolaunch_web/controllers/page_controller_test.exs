defmodule AutolaunchWeb.PageControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  test "root serves the public auction guide", %{conn: conn} do
    conn = get(conn, "/")

    html = html_response(conn, 200)

    assert html =~ "How autolaunch auctions work."
    assert html =~ "USDC on Ethereum mainnet"
  end
end
