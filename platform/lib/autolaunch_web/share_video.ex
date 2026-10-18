defmodule AutolaunchWeb.ShareVideo do
  @moduledoc """
  The share videos of a graduated token: one for everyone, with the token's
  own story, and one for a signed-in wallet, with that wallet's bids, trades,
  stake and earnings on it too (`AutolaunchWeb.ShareVideo.Story`, drawn by
  `AutolaunchWeb.ShareVideo.Film`).

  A video is made once for each fifteen minutes and kept (`cache/0`, at most
  24 videos, the oldest written leaving first). Making one takes the
  machine's attention for a few seconds, so videos are made one at a time on
  their own job queue (`AutolaunchWeb.ShareVideo.Render`) and a request waits
  for its video: the job keeps the finished video and tells every waiting
  request through PubSub.
  """
  alias AutolaunchWeb.Paths
  alias AutolaunchWeb.ShareVideo.Render

  @cache :share_videos
  @kept 24
  @wait_ms 150_000

  @doc "The kept videos' cache and how many it keeps, for the application's supervisor."
  def cache, do: @cache
  def kept, do: @kept

  @doc "Where the token's video for everyone is served, as its figures stand at `now`."
  @spec token_url(struct(), DateTime.t()) :: String.t()
  def token_url(auction, now), do: Paths.token_video_url(auction, bucket(now))

  @doc "Where `wallet`'s own video of the token is served, for its signed-in owner."
  @spec wallet_url(struct(), String.t(), DateTime.t()) :: String.t()
  def wallet_url(auction, wallet, now),
    do: Paths.wallet_video_url(auction, String.downcase(wallet), bucket(now))

  @doc """
  The video's MP4 bytes, kept or made now: the token's own when `wallet` is
  nil, `wallet`'s otherwise.
  """
  @spec fetch(struct(), String.t() | nil, DateTime.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(auction, wallet, now) do
    wallet = wallet && String.downcase(wallet)
    key = key(auction, wallet, now)

    case Cachex.get(@cache, key) do
      {:ok, mp4} when is_binary(mp4) -> {:ok, mp4}
      _missing -> made(auction, wallet, key)
    end
  end

  # Subscribed before the job is queued and the cache read once more, so a
  # video finished in between is never missed.
  defp made(auction, wallet, key) do
    :ok = Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(key))

    try do
      {:ok, _job} =
        Oban.insert(
          Render.new(%{
            "symbol" => auction.token_symbol,
            "tail" => auction.path_tail,
            "wallet" => wallet,
            "key" => key
          })
        )

      case Cachex.get(@cache, key) do
        {:ok, mp4} when is_binary(mp4) -> {:ok, mp4}
        _missing -> await(key)
      end
    after
      Phoenix.PubSub.unsubscribe(Autolaunch.PubSub, topic(key))
    end
  end

  defp await(key) do
    receive do
      {:share_video, ^key, :made} ->
        case Cachex.get(@cache, key) do
          {:ok, mp4} when is_binary(mp4) -> {:ok, mp4}
          _gone -> {:error, :video_unavailable}
        end

      {:share_video, ^key, {:failed, reason}} ->
        {:error, reason}
    after
      @wait_ms -> {:error, :video_timeout}
    end
  end

  @doc false
  # The finished video, kept and announced to every request waiting for it.
  def made!(key, mp4) do
    {:ok, true} = Cachex.put(@cache, key, mp4)
    Phoenix.PubSub.broadcast(Autolaunch.PubSub, topic(key), {:share_video, key, :made})
  end

  @doc false
  def failed(key, reason),
    do:
      Phoenix.PubSub.broadcast(
        Autolaunch.PubSub,
        topic(key),
        {:share_video, key, {:failed, reason}}
      )

  defp key(auction, wallet, now),
    do: Enum.join([auction.id, wallet, bucket(now)], ":")

  defp topic(key), do: "share_video:" <> key

  defp bucket(now), do: now |> DateTime.to_unix() |> div(900) |> Integer.to_string()
end
