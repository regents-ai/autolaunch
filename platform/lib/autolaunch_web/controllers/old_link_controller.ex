defmodule AutolaunchWeb.OldLinkController do
  @moduledoc """
  The addresses auctions and tokens had before their pages were named by
  ticker (`AutolaunchWeb.Paths`): a Base auction or token by its id, a
  Robinhood one by its contract address, and an auction's share picture under
  either. Links to them were shared, so each moves permanently to the
  record's address today; a page keeps its query. Anything they do not name
  is the site's 404.
  """
  use AutolaunchWeb, :controller

  alias Autolaunch.Chain.Address
  alias AutolaunchWeb.{NotFoundError, Paths, ShareCard}

  def base_auction(conn, %{"auction_id" => id}),
    do: move(conn, Paths.auction(base_auction!(id)) |> with_query(conn.query_string))

  def robinhood_auction(conn, %{"auction" => address}),
    do: move(conn, Paths.auction(robinhood_auction!(address)) |> with_query(conn.query_string))

  def base_auction_image(conn, %{"auction_id" => id}),
    do: move(conn, ShareCard.auction_image_url(base_auction!(id), DateTime.utc_now()))

  def robinhood_auction_image(conn, %{"auction" => address}),
    do: move(conn, ShareCard.auction_image_url(robinhood_auction!(address), DateTime.utc_now()))

  def base_token(conn, %{"token_id" => id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %{auction: auction}} <- Autolaunch.get_public_token(id, actor: nil) do
      move(conn, Paths.token(auction) |> with_query(conn.query_string))
    else
      _missing -> raise NotFoundError
    end
  end

  def robinhood_token(conn, %{"token" => address}) do
    with {:ok, address} <- Address.normalize(address),
         {:ok, %{auction: auction}} <- Autolaunch.get_robinhood_token(address, actor: nil) do
      move(conn, Paths.token(auction) |> with_query(conn.query_string))
    else
      _missing -> raise NotFoundError
    end
  end

  defp base_auction!(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %{} = auction} <- Autolaunch.get_public_auction(id, actor: nil, load: [:fdv]) do
      auction
    else
      _missing -> raise NotFoundError
    end
  end

  defp robinhood_auction!(address) do
    with {:ok, address} <- Address.normalize(address),
         {:ok, %{} = auction} <-
           Autolaunch.get_robinhood_auction(address, actor: nil, load: [:fdv]) do
      auction
    else
      _missing -> raise NotFoundError
    end
  end

  defp move(conn, address) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(external: address)
  end

  defp with_query(path, ""), do: path
  defp with_query(path, query), do: path <> "?" <> query
end
