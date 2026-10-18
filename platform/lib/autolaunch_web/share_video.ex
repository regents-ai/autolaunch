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

  Videos are made one at a time on their own job queue
  (`AutolaunchWeb.ShareVideo.Render`). Asking for one that is not made yet
  queues it, once however many ask, and answers how many videos are ahead of
  it; asking again answers the video once it is made. Each account makes at
  most three new videos of its own in any 24 hours, counted from its jobs on
  the queue; a video already made, and every launch's own video, never count.
  """
  alias Autolaunch.{TokenTrades, WalletHistory}
  alias AutolaunchWeb.Paths
  alias AutolaunchWeb.ShareVideo.Render

  @cache :share_videos
  @kept 24
  @daily 3
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

  @doc "How many videos of its own an account may make in any 24 hours."
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
  def fetch(auction, phase, nil, nil, now),
    do: kept_or_queued(auction, phase, nil, nil, key(auction, phase, [], now))

  def fetch(auction, phase, wallet, account, now) when is_integer(account) do
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
         do: WalletHistory.holding(auction.token_address, wallet, venue.opts)
  end

  defp wallet_state(auction, :auction, wallet) do
    with {:ok, bids} <- Autolaunch.auction_bids(auction.id, actor: nil) do
      own = Enum.filter(bids, &(&1.bidder == wallet))

      {:ok,
       "#{length(own)}-#{own |> Enum.map(& &1.amount) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)}"}
    end
  end

  defp kept_or_queued(auction, phase, wallet, account, key) do
    with :none <- kept(key),
         :none <- pending(key),
         :ok <- allowed(account),
         :none <- kept(key) do
      queue(auction, phase, wallet, account, key)
    end
  end

  defp kept(key) do
    case Cachex.get(@cache, key) do
      {:ok, mp4} when is_binary(mp4) -> {:ok, mp4}
      {:ok, :failed} -> {:error, :render_failed}
      _missing -> :none
    end
  end

  defp pending(key) do
    case Render.pending(key) do
      nil -> :none
      job -> {:waiting, Render.ahead(job)}
    end
  end

  defp allowed(nil), do: :ok

  defp allowed(account),
    do: if(Render.made_today(account) < @daily, do: :ok, else: {:error, :daily_limit})

  defp queue(auction, phase, wallet, account, key) do
    args =
      %{
        "symbol" => auction.token_symbol,
        "tail" => auction.path_tail,
        "phase" => Atom.to_string(phase),
        "wallet" => wallet,
        "key" => key
      }

    args = if account, do: Map.put(args, "account", account), else: args
    {:ok, job} = Oban.insert(Render.new(args))
    {:waiting, Render.ahead(job)}
  end

  @doc false
  # The finished video, kept for every request that asks for it next.
  def made!(key, mp4) do
    {:ok, true} = Cachex.put(@cache, key, mp4)
    :ok
  end

  @doc false
  # A video that could not be made answers so for a short while; asking again
  # after that queues it again.
  def failed(key) do
    {:ok, true} = Cachex.put(@cache, key, :failed, expire: @failed_ms)
    :ok
  end

  defp key(auction, phase, wallet_parts, now),
    do: Enum.join([auction.id, phase | wallet_parts] ++ [bucket(now)], ":")

  defp bucket(now), do: now |> DateTime.to_unix() |> div(900) |> Integer.to_string()
end
