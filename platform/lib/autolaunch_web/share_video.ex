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
  shows straight away. Making one takes the
  machine's attention for a few seconds, so videos are made one at a time on
  their own job queue (`AutolaunchWeb.ShareVideo.Render`) and a request waits
  for its video: the job keeps the finished video and tells every waiting
  request through PubSub.
  """
  alias Autolaunch.{TokenTrades, WalletHistory}
  alias AutolaunchWeb.Paths
  alias AutolaunchWeb.ShareVideo.Render

  @cache :share_videos
  @kept 24
  @wait_ms 150_000

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
  The video's MP4 bytes, kept or made now: the token's (`:token`) or the
  running auction's (`:auction`), everyone's when `wallet` is nil and
  `wallet`'s otherwise.
  """
  @spec fetch(struct(), :token | :auction, String.t() | nil, DateTime.t()) ::
          {:ok, binary()} | {:error, term()}
  def fetch(auction, phase, nil, now),
    do: kept_or_made(auction, phase, nil, key(auction, phase, [], now))

  def fetch(auction, phase, wallet, now) do
    wallet = String.downcase(wallet)

    with {:ok, state} <- wallet_state(auction, phase, wallet),
         do: kept_or_made(auction, phase, wallet, key(auction, phase, [wallet, state], now))
  end

  # What a wallet has in the launch now, read cheaply: its holding of the
  # token, or during the auction how many bids it has placed and their total.
  defp wallet_state(auction, :token, wallet) do
    with {:ok, venue} <- TokenTrades.venue(auction),
         do: WalletHistory.holding(auction.token_address, wallet, venue.opts)
  end

  defp wallet_state(auction, :auction, wallet) do
    with {:ok, bids} <- Autolaunch.auction_bids(auction.id, actor: nil) do
      own = Enum.filter(bids, &(&1.bidder == wallet))

      {:ok,
       "#{length(own)}-#{own |> Enum.map(& &1.amount) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)}"}
    end
  end

  defp kept_or_made(auction, phase, wallet, key) do
    case Cachex.get(@cache, key) do
      {:ok, mp4} when is_binary(mp4) -> {:ok, mp4}
      _missing -> made(auction, phase, wallet, key)
    end
  end

  # Subscribed before the job is queued and the cache read once more, so a
  # video finished in between is never missed.
  defp made(auction, phase, wallet, key) do
    :ok = Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(key))

    try do
      {:ok, _job} =
        Oban.insert(
          Render.new(%{
            "symbol" => auction.token_symbol,
            "tail" => auction.path_tail,
            "phase" => Atom.to_string(phase),
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

  defp key(auction, phase, wallet_parts, now),
    do: Enum.join([auction.id, phase | wallet_parts] ++ [bucket(now)], ":")

  defp topic(key), do: "share_video:" <> key

  defp bucket(now), do: now |> DateTime.to_unix() |> div(900) |> Integer.to_string()
end
