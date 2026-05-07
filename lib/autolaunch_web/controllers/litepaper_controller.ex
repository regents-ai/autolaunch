defmodule AutolaunchWeb.LitepaperController do
  use AutolaunchWeb, :controller

  def pdf(conn, _params) do
    conn
    |> put_resp_header("content-type", "application/pdf")
    |> put_resp_header("content-disposition", ~s(inline; filename="autolaunch-litepaper.pdf"))
    |> send_file(200, litepaper_path("autolaunch-litepaper.pdf"))
  end

  def markdown(conn, _params) do
    conn
    |> put_resp_content_type("text/markdown")
    |> put_resp_header("content-disposition", ~s(inline; filename="autolaunch-litepaper.md"))
    |> send_file(200, litepaper_path("litepaper.md"))
  end

  defp litepaper_path(filename) do
    [:code.priv_dir(:autolaunch), "static", "litepaper", filename]
    |> Enum.map(&to_string/1)
    |> Path.join()
  end
end
