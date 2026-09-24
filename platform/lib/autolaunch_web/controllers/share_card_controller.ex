defmodule AutolaunchWeb.ShareCardController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Chain.Address
  alias AutolaunchWeb.ShareCard

  def base(conn, %{"auction_id" => id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %{} = auction} <-
           Autolaunch.get_public_auction(id, actor: nil, load: [:fdv]) do
      send_card(conn, auction)
    else
      _missing -> not_found(conn)
    end
  end

  def robinhood(conn, %{"auction" => address}) do
    with {:ok, address} <- Address.normalize(address),
         {:ok, %{} = auction} <-
           Autolaunch.get_robinhood_auction(address, actor: nil, load: [:fdv]) do
      send_card(conn, auction)
    else
      _missing -> not_found(conn)
    end
  end

  # The picture carries the time its figures were read, and sites that show
  # it keep their own copy, so it is kept for five minutes here.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp send_card(conn, auction) do
    {:ok, png} = ShareCard.png(auction, DateTime.utc_now())

    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> put_resp_content_type("image/png", nil)
    |> send_resp(200, png)
  end

  defp not_found(conn), do: send_resp(conn, 404, "Not found")
end
