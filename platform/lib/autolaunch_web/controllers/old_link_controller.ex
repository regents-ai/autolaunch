defmodule AutolaunchWeb.OldLinkController do
  @moduledoc """
  The addresses auctions and tokens had before their pages were named by
  ticker (`AutolaunchWeb.Paths`): a Base auction or token by its id, a
  Robinhood one by its contract address, and an auction's share picture under
  either. Links to them were shared, so each moves permanently to the
  record's address today; a page keeps its query. Anything they do not name
  is the site's 404; a read that fails answers as a market page's does
  (`AutolaunchWeb.ReadFailure`), never as a missing page.
  """
  use AutolaunchWeb, :controller

  alias AutolaunchWeb.{NotFoundError, Paths, ReadFailure, ShareCard}
  alias RegentChain.Address

  def base_auction(conn, %{"auction_id" => id}),
    do: move(conn, Paths.auction(base_auction!(id)) |> with_query(conn.query_string))

  def robinhood_auction(conn, %{"auction" => address}),
    do: move(conn, Paths.auction(robinhood_auction!(address)) |> with_query(conn.query_string))

  def base_auction_image(conn, %{"auction_id" => id}),
    do: move(conn, ShareCard.auction_image_url(base_auction!(id), DateTime.utc_now()))

  def robinhood_auction_image(conn, %{"auction" => address}),
    do: move(conn, ShareCard.auction_image_url(robinhood_auction!(address), DateTime.utc_now()))

  def base_token(conn, %{"token_id" => id}) do
    %{auction: auction} = found!(Ecto.UUID.cast(id), &Autolaunch.get_public_token(&1, actor: nil))
    move(conn, Paths.token(auction) |> with_query(conn.query_string))
  end

  def robinhood_token(conn, %{"token" => address}) do
    %{auction: auction} =
      found!(Address.normalize(address), &Autolaunch.get_robinhood_token(&1, actor: nil))

    move(conn, Paths.token(auction) |> with_query(conn.query_string))
  end

  defp base_auction!(id),
    do: found!(Ecto.UUID.cast(id), &Autolaunch.get_public_auction(&1, actor: nil, load: [:fdv]))

  defp robinhood_auction!(address),
    do:
      found!(
        Address.normalize(address),
        &Autolaunch.get_robinhood_auction(&1, actor: nil, load: [:fdv])
      )

  # The record `read` finds under an address that names one, or the site's
  # 404 when the address cannot name one or nothing is there. A read that
  # fails is never a missing record: it answers as a market page's does
  # (`AutolaunchWeb.ReadFailure`).
  defp found!({:ok, key}, read) do
    case read.(key) do
      {:ok, %{} = record} -> record
      {:ok, nil} -> raise NotFoundError
      {:error, %Ash.Error.Invalid{}} -> raise NotFoundError
      {:error, error} -> ReadFailure.raise!("old link read", error)
    end
  end

  defp found!(:error, _read), do: raise(NotFoundError)

  defp move(conn, address) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(external: address)
  end

  defp with_query(path, ""), do: path
  defp with_query(path, query), do: path <> "?" <> query
end
