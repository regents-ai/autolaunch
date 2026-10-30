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
        send_video(
          conn,
          "public",
          ShareVideo.fetch(auction, :token, nil, nil, DateTime.utc_now())
        )

      :error ->
        raise NotFoundError
    end
  end

  @doc """
  One wallet's share video, only for the signed-in account that links the
  wallet; for anyone else there is nothing at the address.
  """
  def wallet_video(conn, %{"symbol" => symbol, "tail" => tail, "wallet" => wallet}) do
    account = conn.assigns[:current_human_account]

    with {:ok, wallet} <- Address.normalize(wallet),
         true <- linked?(account, wallet),
         {:ok, auction, _token} <- Paths.find_token(symbol, tail) do
      send_video(
        conn,
        "private",
        ShareVideo.fetch(auction, :token, wallet, account.id, DateTime.utc_now())
      )
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
        send_video(
          conn,
          "public",
          ShareVideo.fetch(auction, :auction, nil, nil, DateTime.utc_now())
        )

      :error ->
        raise NotFoundError
    end
  end

  @doc "One wallet's share video of the auction, on the same terms as `wallet_video/2`."
  def auction_wallet_video(conn, %{"symbol" => symbol, "tail" => tail, "wallet" => wallet}) do
    account = conn.assigns[:current_human_account]

    with {:ok, wallet} <- Address.normalize(wallet),
         true <- linked?(account, wallet),
         {:ok, auction} <- Paths.find_auction(symbol, tail) do
      now = DateTime.utc_now()

      if auction.state == :graduated,
        do: moved(conn, ShareVideo.url(auction, wallet, now)),
        else:
          send_video(
            conn,
            "private",
            ShareVideo.fetch(auction, :auction, wallet, account.id, now)
          )
    else
      _not_theirs -> raise NotFoundError
    end
  end

  @doc "A covered-call market's picture, for any market the site offers."
  def covered_calls(conn, %{"symbol" => symbol}) do
    symbol = covered_calls_market!(symbol)
    market_card(conn, ShareCard.market_png(:covered_calls, symbol, DateTime.utc_now()))
  end

  @doc "A covered-call market's share video for everyone."
  def covered_calls_video(conn, %{"symbol" => symbol}) do
    symbol = covered_calls_market!(symbol)

    send_video(
      conn,
      "public",
      ShareVideo.fetch_market(:covered_calls, symbol, nil, nil, DateTime.utc_now())
    )
  end

  @doc "One wallet's share video of a covered-call market, on the same terms as `wallet_video/2`."
  def covered_calls_wallet_video(conn, %{"symbol" => symbol, "wallet" => wallet}) do
    symbol = covered_calls_market!(symbol)
    market_wallet_video(conn, :covered_calls, symbol, wallet)
  end

  @doc "An After-hours Exposure series' picture, for any series the site offers."
  def exposure(conn, %{"series" => series}) do
    series = exposure_series!(series)
    market_card(conn, ShareCard.market_png(:exposure, series, DateTime.utc_now()))
  end

  @doc "An After-hours Exposure series' share video for everyone."
  def exposure_video(conn, %{"series" => series}) do
    series = exposure_series!(series)

    send_video(
      conn,
      "public",
      ShareVideo.fetch_market(:exposure, series, nil, nil, DateTime.utc_now())
    )
  end

  @doc "One wallet's share video of an After-hours Exposure series, on the same terms as `wallet_video/2`."
  def exposure_wallet_video(conn, %{"series" => series, "wallet" => wallet}) do
    series = exposure_series!(series)
    market_wallet_video(conn, :exposure, series, wallet)
  end

  # A market's picture is drawn from the chain; one the chain cannot answer
  # for is the site's try-again page.
  defp market_card(conn, {:ok, _png} = drawn), do: send_card(conn, drawn)
  defp market_card(_conn, {:error, _reason}), do: raise(UnavailableError)

  defp market_wallet_video(conn, kind, subject, wallet) do
    account = conn.assigns[:current_human_account]

    with {:ok, wallet} <- Address.normalize(wallet),
         true <- linked?(account, wallet) do
      send_video(
        conn,
        "private",
        ShareVideo.fetch_market(kind, subject, wallet, account.id, DateTime.utc_now())
      )
    else
      _not_theirs -> raise NotFoundError
    end
  end

  # The market as the site's description writes its symbol; any other is not there.
  defp covered_calls_market!(symbol) do
    case Autolaunch.CoveredCalls.Deployment.market(symbol) do
      {:ok, market} -> market.symbol
      {:error, _unknown} -> raise NotFoundError
    end
  end

  # The series' address as the site's description lists it, in any case.
  defp exposure_series!(series) do
    case Autolaunch.Exposure.Deployment.series(series) do
      {:ok, address} -> address
      {:error, _unknown} -> raise NotFoundError
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

  # A video's address moves on with its figures, like the picture's. Until
  # it is made, the answer says how many videos are ahead of it, and the
  # share window asks again; once the site has made all of the day's videos,
  # a person with none saved is told so, and the window offers the launch's
  # own video. Only a database that cannot be reached is the site's try-again
  # page; every other failure answers with its own plain line, which the share
  # window shows.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp send_video(conn, reach, {:ok, mp4}) do
    conn
    |> put_resp_header("cache-control", "#{reach}, max-age=900")
    |> put_resp_content_type("video/mp4", nil)
    |> send_resp(200, mp4)
  end

  defp send_video(conn, _reach, {:waiting, ahead}) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("retry-after", "2")
    |> put_status(:accepted)
    |> json(%{ahead: ahead})
  end

  defp send_video(_conn, _reach, {:error, :connection_lost}), do: raise(UnavailableError)

  defp send_video(conn, _reach, {:error, :daily_limit}) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:too_many_requests)
    |> json(%{message: "Error making video, try tomorrow"})
  end

  defp send_video(conn, _reach, {:error, reason}) do
    {status, message} = failed(reason)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{error: reason, message: message})
  end

  defp failed(:render_failed),
    do: {:internal_server_error, "Your video couldn't be made. Try again in a moment."}

  defp failed(:invalid_request),
    do: {:unprocessable_entity, "A video can't be made for this address."}

  defp failed(:failed),
    do:
      {:internal_server_error,
       "Your video couldn't be asked for just now. Try again in a moment."}

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
