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
  as made until three hours have passed; asking after that makes a new one,
  and the old ones stay stored.

  Asking for a video that is not made yet queues it to be made one at a time
  (`AutolaunchWeb.ShareVideo.Render`) and answers how many videos are ahead
  of it; asking again answers the video once it is made. The site makes at
  most 1000 videos in any 24 hours; past that a person keeps their last video,
  one who has none is told so and offered the launch's own, and a launch's own
  video is still made.
  """
  require Ash.Query

  alias Autolaunch.Actors.System
  alias Autolaunch.ShareVideoRequest
  alias AutolaunchWeb.Paths

  @daily 1000
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

  @doc "How many videos the site makes in any 24 hours."
  def daily, do: @daily

  @doc """
  The video as it stands: its MP4 bytes once made, or how many videos are
  queued ahead of it. The token's (`:token`) or the running auction's
  (`:auction`), everyone's when `wallet` is nil and otherwise `wallet`'s,
  asked for by the signed-in `account` that links it.
  """
  @spec fetch(struct(), :token | :auction, String.t() | nil, integer() | nil, DateTime.t()) ::
          {:ok, binary()}
          | {:waiting, non_neg_integer()}
          | {:error, :daily_limit | :render_failed | term()}
  def fetch(auction, phase, nil, nil, now) do
    key = key(auction, phase, now)

    case Autolaunch.latest_share_video_request(key, actor: %System{}) do
      {:ok, nil} -> made(auction, phase, nil, nil, key, nil)
      {:ok, request} -> standing(request, fn -> made(auction, phase, nil, nil, key, nil) end)
      error -> error
    end
  end

  def fetch(auction, phase, wallet, account, now) when is_integer(account) do
    with {:ok, own} <-
           Autolaunch.own_share_video_requests(account, auction.id, phase, actor: %System{}) do
      saved = Enum.find(own, &(&1.state == :ready and &1.stored?))
      key = own_key(auction, phase, account)
      remake = fn -> made(auction, phase, String.downcase(wallet), account, key, saved) end
      own_standing(own, saved, now, remake)
    end
  end

  # A person's video as their newest request for it stands: in line, failed
  # moments ago, or else their saved one until three hours have passed.
  defp own_standing([%{state: :queued} = request | _older], _saved, _now, _remake),
    do: {:waiting, ahead(request)}

  defp own_standing([%{state: :failed} = request | _older], saved, now, remake),
    do: failed_lately(request, fn -> kept_or(saved, now, remake) end)

  defp own_standing(_made_or_none, saved, now, remake), do: kept_or(saved, now, remake)

  # A launch's own video as its newest request stands. A ready request that
  # holds no video is made again.
  defp standing(%{state: :ready, stored?: true} = request, _make), do: video(request)
  defp standing(%{state: :ready}, make), do: make.()
  defp standing(%{state: :queued} = request, _make), do: {:waiting, ahead(request)}
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

  # A new video. A launch's own is always made, one every fifteen minutes at
  # most; a person's while the site has made fewer than its daily number, and
  # past that they keep their last one.
  defp made(auction, phase, wallet, account, key, saved) do
    cond do
      is_nil(account) or made_today() < @daily ->
        request =
          Autolaunch.request_share_video!(
            %{
              key: key,
              kind: phase,
              auction_id: auction.id,
              human_account_id: account,
              wallet: wallet
            },
            actor: %System{}
          )

        {:waiting, ahead(request)}

      saved ->
        video(saved)

      true ->
        {:error, :daily_limit}
    end
  end

  defp made_today do
    ShareVideoRequest
    |> Ash.Query.for_read(:made_today, %{}, actor: %System{})
    |> Ash.count!(actor: %System{})
  end

  defp video(request) do
    case Autolaunch.share_video_mp4(request.id, actor: %System{}) do
      {:ok, %{mp4: mp4}} when is_binary(mp4) -> {:ok, mp4}
      _gone -> {:error, :video_unavailable}
    end
  end

  defp ahead(request) do
    ShareVideoRequest
    |> Ash.Query.for_read(:queued, %{}, actor: %System{})
    |> Ash.Query.filter(inserted_at < ^request.inserted_at)
    |> Ash.count!(actor: %System{})
  end

  defp key(auction, phase, now), do: Enum.join([auction.id, phase, bucket(now)], ":")

  defp own_key(auction, phase, account),
    do: Enum.join([auction.id, phase, "account", account], ":")

  defp bucket(now), do: now |> DateTime.to_unix() |> div(900) |> Integer.to_string()
end
