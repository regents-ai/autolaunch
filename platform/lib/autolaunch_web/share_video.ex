defmodule AutolaunchWeb.ShareVideo do
  @moduledoc """
  The share videos of a launch: one for everyone, with the launch's own
  story, and one for a signed-in wallet, with that wallet's bids, trades,
  stake and earnings on it too (`AutolaunchWeb.ShareVideo.Story`, drawn by
  `AutolaunchWeb.ShareVideo.Film`). A launch still in its auction has its
  video at the auction's address; a graduated one at its token's.

  A video is made once for each fifteen minutes and kept (`cache/0`, at most
  24 videos, the oldest written leaving first). A wallet's video is also made
  again as soon as the wallet's holding of the token changes, or during the
  auction as soon as it bids again, so a new bid, stake, unstake, buy or sell
  shows straight away.

  Asking for a video that is not made yet records an
  `Autolaunch.ShareVideoRequest`, once however many ask, which queues it to be
  made one at a time (`AutolaunchWeb.ShareVideo.Render`), and answers how many
  videos are ahead of it; asking again answers the video once it is made. Each
  account makes at most three new videos of its own in any 24 hours, however
  many of its requests arrive at once, counted by the request's own write
  (`Autolaunch.ShareVideoRequest.Changes.DailyLimit`); a video already made,
  and every launch's own video, never count.
  """
  alias Autolaunch.{TokenTrades, WalletHistory}
  require Ash.Query
  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.ShareVideoRequest
  alias AutolaunchWeb.Paths

  @cache :share_videos
  @kept 24
  @failed_ms 30_000

  @doc "The kept videos' cache and how many it keeps, for the application's supervisor."
  def cache, do: @cache
  def kept, do: @kept

  @doc """
  Where the launch's video is served as it stands at `now`: the auction's
  while it runs, the token's once it has graduated; `wallet`'s own when one
  is given.
  """
  @spec url(struct(), String.t() | nil, DateTime.t()) :: String.t()
  def url(%{state: :graduated} = auction, nil, now), do: token_url(auction, now)
  def url(%{state: :graduated} = auction, wallet, now), do: wallet_url(auction, wallet, now)
  def url(auction, nil, now), do: Paths.auction_video_url(auction, bucket(now))

  def url(auction, wallet, now),
    do: Paths.auction_wallet_video_url(auction, String.downcase(wallet), bucket(now))

  @doc "Where the token's video for everyone is served, as its figures stand at `now`."
  @spec token_url(struct(), DateTime.t()) :: String.t()
  def token_url(auction, now), do: Paths.token_video_url(auction, bucket(now))

  @doc "Where `wallet`'s own video of the token is served, for its signed-in owner."
  @spec wallet_url(struct(), String.t(), DateTime.t()) :: String.t()
  def wallet_url(auction, wallet, now),
    do: Paths.wallet_video_url(auction, String.downcase(wallet), bucket(now))

  @doc """
  The video as it stands: its MP4 bytes once made, or how many videos are
  queued ahead of it. The token's (`:token`) or the running auction's
  (`:auction`), everyone's when `wallet` is nil and otherwise `wallet`'s,
  asked for by the signed-in `account` that links it.

  A failure names what went wrong: `:daily_limit` (the account has made its
  videos for the day), `:render_failed` (the video could not be made moments
  ago), `:chain_read_failed` (the wallet's holding could not be read from the
  chain), `:invalid_request` (the request was refused as written),
  `:connection_lost` (the database could not be reached) or `:failed`
  (anything else).
  """
  @spec fetch(struct(), :token | :auction, String.t() | nil, integer() | nil, DateTime.t()) ::
          {:ok, binary()}
          | {:waiting, non_neg_integer()}
          | {:error,
             :daily_limit
             | :render_failed
             | :chain_read_failed
             | :invalid_request
             | :connection_lost
             | :failed}
  def fetch(auction, phase, wallet, account, now) do
    answer(auction, phase, wallet, account, now)
  rescue
    # Ash returns most failed reads and writes, but raises some: a connection
    # lost inside a write's transaction (`Ash.Error.Unknown`) and any failure
    # of a count (the database's own exception).
    error in [Ash.Error.Unknown, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, failure(error)}
  end

  defp answer(auction, phase, nil, nil, now),
    do: kept_or_queued(auction, phase, nil, nil, key(auction, phase, [], now))

  defp answer(auction, phase, wallet, account, now) when is_integer(account) do
    wallet = String.downcase(wallet)

    with {:ok, state} <- wallet_state(auction, phase, wallet),
         do:
           kept_or_queued(
             auction,
             phase,
             wallet,
             account,
             key(auction, phase, [wallet, state], now)
           )
  end

  # What a wallet has in the launch now, read cheaply: its holding of the
  # token, or during the auction how many bids it has placed and their total.
  defp wallet_state(auction, :token, wallet) do
    with {:ok, venue} <- TokenTrades.venue(auction),
         {:ok, holding} <- WalletHistory.holding(auction.token_address, wallet, venue.opts) do
      {:ok, holding}
    else
      {:error, _unread} -> {:error, :chain_read_failed}
    end
  end

  defp wallet_state(auction, :auction, wallet) do
    case Autolaunch.auction_bids(auction.id, actor: nil) do
      {:ok, bids} ->
        own = Enum.filter(bids, &(&1.bidder == wallet))

        {:ok,
         "#{length(own)}-#{own |> Enum.map(& &1.amount) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)}"}

      {:error, error} ->
        {:error, failure(error)}
    end
  end

  defp kept_or_queued(auction, phase, wallet, account, key) do
    with :none <- kept(key),
         :none <- requested(key),
         :none <- kept(key) do
      request(auction, phase, wallet, account, key)
    end
  end

  defp kept(key) do
    case Cachex.get(@cache, key) do
      {:ok, mp4} when is_binary(mp4) -> {:ok, mp4}
      _missing -> :none
    end
  end

  # A request still queued gives its place in line; one that failed moments
  # ago says so, and after that the next ask queues it again.
  defp requested(key) do
    case Autolaunch.latest_share_video_request(key, actor: %System{}) do
      {:ok, %{state: :queued} = request} -> waiting(request)
      {:ok, %{state: :failed} = request} -> failed_lately(request)
      {:ok, _ready_or_none} -> :none
      {:error, error} -> {:error, failure(error)}
    end
  end

  defp failed_lately(request) do
    if DateTime.diff(DateTime.utc_now(), request.updated_at, :millisecond) < @failed_ms,
      do: {:error, :render_failed},
      else: :none
  end

  # Its place in line: how many requests still queued were made before it.
  defp waiting(request) do
    ShareVideoRequest
    |> Ash.Query.for_read(:queued, %{}, actor: %System{})
    |> Ash.Query.filter(inserted_at < ^request.inserted_at)
    |> Ash.count(actor: %System{})
    |> case do
      {:ok, ahead} -> {:waiting, ahead}
      {:error, error} -> {:error, failure(error)}
    end
  end

  # An account past its videos for the day is told so (`DailyLimit`).
  defp request(auction, phase, wallet, account, key) do
    case Autolaunch.request_share_video(
           %{
             key: key,
             kind: phase,
             auction_id: auction.id,
             human_account_id: account,
             wallet: wallet
           },
           actor: %System{}
         ) do
      {:ok, request} ->
        waiting(request)

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Invalid.Unavailable{reason: :daily_limit}]}} ->
        {:error, :daily_limit}

      {:error, error} ->
        {:error, failure(error)}
    end
  end

  # A database read or write that failed: the database could not be reached
  # (`:connection_lost`), the request was refused as written
  # (`:invalid_request`), or something else went wrong (`:failed`). Every
  # failure is logged where it is sorted, so none passes unseen: a failed read
  # or write as an error, the other two as warnings. The line names only the
  # kind and the module of each error Ash hands over, with the code of a real
  # `Postgrex.Error`, never any of an error's text, so no wallet, address or
  # other value reaches the log.
  defp failure(error) do
    kind = kind(error)
    Logger.log(level(kind), "share video request #{kind}: #{named(error)}")
    kind
  end

  defp kind(%Ash.Error.Invalid{}), do: :invalid_request
  defp kind(error), do: if(connection_lost?(error), do: :connection_lost, else: :failed)

  defp level(:failed), do: :error
  defp level(_kind), do: :warning

  defp named(%Postgrex.Error{postgres: %{pg_code: code}}), do: "Postgrex.Error #{code}"
  defp named(%{errors: errors}) when is_list(errors), do: Enum.map_join(errors, ", ", &named/1)
  defp named(%struct{}), do: inspect(struct)

  # A lost connection: the connection's own error, or a Postgres error whose
  # code is a connection exception (class 08) or a server shutting down or
  # starting (57P01 to 57P03).
  @connection_codes ~w(08000 08001 08003 08004 08006 08007 08P01 57P01 57P02 57P03)

  # AshPostgres keeps only the formatted text of an exception it did not
  # expect (`handle_raised_error/4` in deps/ash_postgres/lib/data_layer.ex
  # hands it to Splode's `to_error/2`, which stores
  # `Exception.format(:error, exception)` in `Ash.Error.Unknown.UnknownError`),
  # so for that one error a lost connection is told by the banner the text
  # starts with. The check gives only true or false.
  @lost_banners ["** (DBConnection.ConnectionError) "] ++
                  for(
                    severity <- ~w(ERROR FATAL PANIC),
                    code <- @connection_codes,
                    do: "** (Postgrex.Error) #{severity} #{code} "
                  )

  defp connection_lost?(%DBConnection.ConnectionError{}), do: true

  defp connection_lost?(%Postgrex.Error{postgres: %{pg_code: code}}),
    do: code in @connection_codes

  defp connection_lost?(%Ash.Error.Unknown.UnknownError{error: text}) when is_binary(text),
    do: String.starts_with?(text, @lost_banners)

  defp connection_lost?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &connection_lost?/1)

  defp connection_lost?(_other), do: false

  @doc false
  # The finished video, kept for every request that asks for it next.
  def made!(key, mp4) do
    {:ok, true} = Cachex.put(@cache, key, mp4)
    :ok
  end

  defp key(auction, phase, wallet_parts, now),
    do: Enum.join([auction.id, phase | wallet_parts] ++ [bucket(now)], ":")

  defp bucket(now), do: now |> DateTime.to_unix() |> div(900) |> Integer.to_string()
end
