defmodule AutolaunchWeb.ShareCardController do
  use AutolaunchWeb, :controller

  alias AutolaunchWeb.{NotFoundError, Paths, ShareCard, ShareVideo, UnavailableError}
  alias RegentChain.Address

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

  @doc "The token's share video for everyone."
  def token_video(conn, %{"symbol" => symbol, "tail" => tail}) do
    case Paths.find_token(symbol, tail) do
      {:ok, auction, _token} ->
        send_video(conn, "public", ShareVideo.fetch(auction, :token, nil, DateTime.utc_now()))

      :error ->
        raise NotFoundError
    end
  end

  @doc """
  One wallet's share video, only for the signed-in account that links the
  wallet; for anyone else there is nothing at the address.
  """
  def wallet_video(conn, %{"symbol" => symbol, "tail" => tail, "wallet" => wallet}) do
    with {:ok, wallet} <- Address.normalize(wallet),
         true <- linked?(conn.assigns[:current_human_account], wallet),
         {:ok, auction, _token} <- Paths.find_token(symbol, tail) do
      send_video(conn, "private", ShareVideo.fetch(auction, :token, wallet, DateTime.utc_now()))
    else
      _not_theirs -> raise NotFoundError
    end
  end

  @doc """
  The running auction's share video for everyone. Once the auction has
  graduated its address moves on for good to the token's video.
  """
  def auction_video(conn, %{"symbol" => symbol, "tail" => tail}) do
    case Paths.find_auction(symbol, tail) do
      {:ok, %{state: :graduated} = auction} ->
        moved(conn, ShareVideo.url(auction, nil, DateTime.utc_now()))

      {:ok, auction} ->
        send_video(conn, "public", ShareVideo.fetch(auction, :auction, nil, DateTime.utc_now()))

      :error ->
        raise NotFoundError
    end
  end

  @doc "One wallet's share video of the auction, on the same terms as `wallet_video/2`."
  def auction_wallet_video(conn, %{"symbol" => symbol, "tail" => tail, "wallet" => wallet}) do
    with {:ok, wallet} <- Address.normalize(wallet),
         true <- linked?(conn.assigns[:current_human_account], wallet),
         {:ok, auction} <- Paths.find_auction(symbol, tail) do
      now = DateTime.utc_now()

      if auction.state == :graduated,
        do: moved(conn, ShareVideo.url(auction, wallet, now)),
        else: send_video(conn, "private", ShareVideo.fetch(auction, :auction, wallet, now))
    else
      _not_theirs -> raise NotFoundError
    end
  end

  defp moved(conn, address) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(external: address)
  end

  defp linked?(%{wallet_addresses: wallets}, wallet) when is_list(wallets),
    do: Enum.any?(wallets, &(String.downcase(&1) == String.downcase(wallet)))

  defp linked?(_signed_out, _wallet), do: false

  # A video's address moves on with its figures, like the picture's.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp send_video(conn, reach, {:ok, mp4}) do
    conn
    |> put_resp_header("cache-control", "#{reach}, max-age=900")
    |> put_resp_content_type("video/mp4", nil)
    |> send_resp(200, mp4)
  end

  defp send_video(_conn, _reach, {:error, _reason}), do: raise(UnavailableError)

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
