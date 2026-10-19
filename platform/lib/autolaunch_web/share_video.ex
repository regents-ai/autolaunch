defmodule AutolaunchWeb.ShareVideo do
  @moduledoc """
  The share videos of a launch: one for everyone, with the launch's own
  story, and one for a signed-in person, with their wallet's bids, trades,
  stake and earnings on it too (`AutolaunchWeb.ShareVideo.Story`, drawn by
  `AutolaunchWeb.ShareVideo.Film`). A launch still in its auction has its
  video at the auction's address; a graduated one at its token's.

  Every video is stored once made (`Autolaunch.ShareVideoRequest`). A launch's
  own video is made again every fifteen minutes it is asked for. A person's
  video for a launch, its auction's and its token's apart, is kept and served
  as made until three hours have passed; asking after that makes a new one.
  Every video is deleted once it is a day old, and sooner, oldest first, if
  the made videos would hold more than 5 GB.

  Asking for a video that is not made yet records a request, once however
  many ask, which queues it to be made one at a time
  (`AutolaunchWeb.ShareVideo.Render`), and answers how many videos are ahead
  of it; asking again answers the video once it is made. The site makes at
  most 1000 videos in any 24 hours, however many requests arrive at once
  (`Autolaunch.ShareVideoRequest.Changes.DailyLimit`); past that a person
  keeps their last video, one who has none is told so and offered the
  launch's own, and a launch's own video is still made.
  """
  require Ash.Query
  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.ShareVideoRequest
  alias AutolaunchWeb.Paths

  @remake_s 3 * 3600
  @failed_ms 30_000

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

  A failure names what went wrong: `:daily_limit` (the site has made all of
  the day's videos and the person has none saved), `:render_failed` (the
  video could not be made moments ago), `:invalid_request` (the request was
  refused as written), `:connection_lost` (the database could not be
  reached) or `:failed` (anything else).
  """
  @spec fetch(struct(), :token | :auction, String.t() | nil, integer() | nil, DateTime.t()) ::
          {:ok, binary()}
          | {:waiting, non_neg_integer()}
          | {:error,
             :daily_limit | :render_failed | :invalid_request | :connection_lost | :failed}
  def fetch(auction, phase, wallet, account, now) do
    answer(auction, phase, wallet, account, now)
  rescue
    # Ash returns most failed reads and writes, but raises some: a connection
    # lost inside a write's transaction (`Ash.Error.Unknown`) and any failure
    # of a count (the database's own exception).
    error in [Ash.Error.Unknown, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, failure(error)}
  end

  defp answer(auction, phase, nil, nil, now) do
    key = key(auction, phase, now)
    make = fn -> made(auction, phase, nil, nil, key, nil) end

    case Autolaunch.latest_share_video_request(key, actor: %System{}) do
      {:ok, nil} -> make.()
      {:ok, request} -> standing(request, make)
      {:error, error} -> {:error, failure(error)}
    end
  end

  defp answer(auction, phase, wallet, account, now) when is_integer(account) do
    case Autolaunch.own_share_video_requests(account, auction.id, phase, actor: %System{}) do
      {:ok, own} ->
        saved = Enum.find(own, &(&1.state == :ready and &1.stored?))
        key = own_key(auction, phase, account)
        remake = fn -> made(auction, phase, String.downcase(wallet), account, key, saved) end
        own_standing(own, saved, now, remake)

      {:error, error} ->
        {:error, failure(error)}
    end
  end

  # A person's video as their newest request for it stands: in line, failed
  # moments ago, or else their saved one until three hours have passed.
  defp own_standing([%{state: :queued} = request | _older], _saved, _now, _remake),
    do: waiting(request)

  defp own_standing([%{state: :failed} = request | _older], saved, now, remake),
    do: failed_lately(request, fn -> kept_or(saved, now, remake) end)

  defp own_standing(_made_or_none, saved, now, remake), do: kept_or(saved, now, remake)

  # A launch's own video as its newest request stands. A ready request that
  # holds no video is made again.
  defp standing(%{state: :ready, stored?: true} = request, _make), do: video(request)
  defp standing(%{state: :ready}, make), do: make.()
  defp standing(%{state: :queued} = request, _make), do: waiting(request)
  defp standing(%{state: :failed} = request, make), do: failed_lately(request, make)

  # A person's saved video until three hours have passed; then a new one.
  defp kept_or(nil, _now, remake), do: remake.()

  defp kept_or(saved, now, remake) do
    if DateTime.diff(now, saved.inserted_at) < @remake_s, do: video(saved), else: remake.()
  end

  # A video that failed moments ago says so; after that, asking makes it again.
  defp failed_lately(request, make) do
    if DateTime.diff(DateTime.utc_now(), request.updated_at, :millisecond) < @failed_ms,
      do: {:error, :render_failed},
      else: make.()
  end

  # A new video, queued once however many ask. Past the site's videos for the
  # day (`DailyLimit`) a person keeps their last one, or is told so.
  defp made(auction, phase, wallet, account, key, saved) do
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
        limited(saved)

      {:error, error} ->
        {:error, failure(error)}
    end
  end

  defp limited(nil), do: {:error, :daily_limit}
  defp limited(saved), do: video(saved)

  defp video(request) do
    case Autolaunch.share_video_mp4(request.id, actor: %System{}) do
      {:ok, %{mp4: mp4}} -> {:ok, mp4}
      {:error, error} -> {:error, failure(error)}
    end
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
  # The banners assume the database server reports its messages in English.
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

  defp key(auction, phase, now), do: Enum.join([auction.id, phase, bucket(now)], ":")

  defp own_key(auction, phase, account),
    do: Enum.join([auction.id, phase, "account", account], ":")

  defp bucket(now), do: now |> DateTime.to_unix() |> div(900) |> Integer.to_string()
end
