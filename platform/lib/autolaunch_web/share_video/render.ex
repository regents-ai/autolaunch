defmodule AutolaunchWeb.ShareVideo.Render do
  @moduledoc """
  Makes one share video and keeps it (`AutolaunchWeb.ShareVideo`). The
  `share_videos` queue runs one at a time, so the machine never draws two
  videos at once, and one job runs for each video however many requests ask
  for it. A video that cannot be made is not tried again; it answers so for
  a short while, and the next request after that queues it again.

  Each video made reports what it took as `[:autolaunch, :share_video,
  :rendered]`: the milliseconds, the MP4's bytes and the most memory the BEAM
  held while it ran.
  """
  use Oban.Worker,
    queue: :share_videos,
    max_attempts: 1,
    unique: [keys: [:key], period: :infinity, states: :incomplete]

  import Ecto.Query

  alias Autolaunch.Repo
  alias AutolaunchWeb.{Paths, ShareVideo}
  alias AutolaunchWeb.ShareVideo.{Film, Story}
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"key" => key} = args}) do
    case make(args) do
      {:ok, mp4} ->
        ShareVideo.made!(key, mp4)
        :ok

      {:error, reason} ->
        ShareVideo.failed(key)
        {:cancel, reason}
    end
  rescue
    error ->
      ShareVideo.failed(key)
      reraise error, __STACKTRACE__
  end

  @waiting ~w(available scheduled executing retryable)

  @doc "The job still making the video `key`, or nil."
  def pending(key) do
    from(job in Job,
      where: job.queue == "share_videos" and job.state in @waiting,
      where: fragment("? @> ?", job.args, ^%{"key" => key}),
      limit: 1
    )
    # Oban's own job table, which no Ash resource covers.
    |> Repo.one(prefix: prefix())
  end

  @doc "How many videos the queue makes before `job`'s."
  def ahead(%Job{id: id}) do
    from(job in Job,
      where: job.queue == "share_videos" and job.state in @waiting and job.id < ^id
    )
    # Oban's own job table, which no Ash resource covers.
    |> Repo.aggregate(:count, prefix: prefix())
  end

  @doc """
  How many videos of its own `account` has had made in the last 24 hours:
  its jobs on the queue, apart from those that made nothing. Oban's pruner
  keeps finished jobs for a week.
  """
  def made_today(account) do
    since = DateTime.add(DateTime.utc_now(), -86_400)

    from(job in Job,
      where: job.queue == "share_videos" and job.state not in ~w(cancelled discarded),
      where: fragment("? @> ?", job.args, ^%{"account" => account}),
      where: job.inserted_at > ^since
    )
    # Oban's own job table, which no Ash resource covers.
    |> Repo.aggregate(:count, prefix: prefix())
  end

  defp prefix, do: Oban.config().prefix

  defp make(%{"phase" => phase, "symbol" => symbol, "tail" => tail, "wallet" => wallet}) do
    with {:ok, story, address} <- story(phase, symbol, tail, wallet),
         {:ok, mp4, measured} <- Film.render(story, String.replace(address, ~r{\Ahttps?://}, "")) do
      :telemetry.execute(
        [:autolaunch, :share_video, :rendered],
        Map.take(measured, [:ms, :bytes, :peak_bytes]),
        %{kind: kind(phase, wallet)}
      )

      {:ok, mp4}
    end
  end

  # The story with the address the video's band names: the token's page, or
  # the auction's while it runs.
  defp story("token", symbol, tail, wallet) do
    with {:ok, auction, token} <- found(Paths.find_token(symbol, tail)),
         {:ok, story} <- token_story(auction, token, wallet),
         do: {:ok, story, Paths.token_url(auction)}
  end

  defp story("auction", symbol, tail, wallet) do
    with {:ok, auction} <- found(Paths.find_auction(symbol, tail)),
         {:ok, story} <- Story.auction(auction, wallet),
         do: {:ok, story, Paths.auction_url(auction)}
  end

  defp found(:error), do: {:error, :not_found}
  defp found(found), do: found

  defp token_story(auction, token, nil), do: Story.token(auction, token)
  defp token_story(auction, token, wallet), do: Story.wallet(auction, token, wallet)

  defp kind("token", nil), do: :token
  defp kind("token", _wallet), do: :wallet
  defp kind("auction", nil), do: :auction
  defp kind("auction", _wallet), do: :auction_wallet
end
