defmodule AutolaunchWeb.HealthController do
  use AutolaunchWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(:ok, "ok")
  end
end
