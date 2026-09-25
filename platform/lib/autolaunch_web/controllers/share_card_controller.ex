defmodule AutolaunchWeb.ShareCardController do
  use AutolaunchWeb, :controller

  alias AutolaunchWeb.{Paths, ShareCard}

  def auction(conn, %{"symbol" => symbol, "tail" => tail}) do
    case Paths.find_auction(symbol, tail) do
      {:ok, auction} -> send_card(conn, auction)
      :error -> not_found(conn)
    end
  end

  # The picture carries the time its figures were read, and sites that show
  # it keep their own copy, so it is kept for fifteen minutes here,
  # as long as its address stays the same.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp send_card(conn, auction) do
    {:ok, png} = ShareCard.png(auction, DateTime.utc_now())

    conn
    |> put_resp_header("cache-control", "public, max-age=900")
    |> put_resp_content_type("image/png", nil)
    |> send_resp(200, png)
  end

  defp not_found(conn), do: send_resp(conn, 404, "Not found")
end
