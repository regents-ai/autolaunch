defmodule AutolaunchWeb.ShareCardController do
  use AutolaunchWeb, :controller

  alias AutolaunchWeb.{NotFoundError, Paths, ShareCard}

  def auction(conn, %{"symbol" => symbol, "tail" => tail}) do
    case Paths.find_auction(symbol, tail) do
      {:ok, auction} -> send_card(conn, ShareCard.auction_png(auction, DateTime.utc_now()))
      :error -> raise NotFoundError
    end
  end

  def token(conn, %{"symbol" => symbol, "tail" => tail}) do
    case Paths.find_token(symbol, tail) do
      {:ok, auction, token} ->
        send_card(conn, ShareCard.token_png(auction, token, DateTime.utc_now()))

      :error ->
        raise NotFoundError
    end
  end

  # The picture carries the time its figures were read, and its address
  # moves on when they can have changed (`ShareCard`), so sites may keep it
  # for fifteen minutes.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp send_card(conn, {:ok, png}) do
    conn
    |> put_resp_header("cache-control", "public, max-age=900")
    |> put_resp_content_type("image/png", nil)
    |> send_resp(200, png)
  end
end
