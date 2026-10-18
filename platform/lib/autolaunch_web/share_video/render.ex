defmodule AutolaunchWeb.ShareVideo.Render do
  @moduledoc """
  Makes one share video and keeps it (`AutolaunchWeb.ShareVideo`). The
  `share_videos` queue runs one at a time, so the machine never draws two
  videos at once, and one job runs for each video however many requests ask
  for it. A video that cannot be made is not tried again; the requests
  waiting for it are told, and the next request asks again.

  Each video made reports what it took as `[:autolaunch, :share_video,
  :rendered]`: the milliseconds, the MP4's bytes and the most memory the BEAM
  held while it ran.
  """
  use Oban.Worker,
    queue: :share_videos,
    max_attempts: 1,
    unique: [keys: [:key], period: :infinity, states: :incomplete]

  alias AutolaunchWeb.{Paths, ShareVideo}
  alias AutolaunchWeb.ShareVideo.{Film, Story}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"key" => key} = args}) do
    case make(args) do
      {:ok, mp4} ->
        ShareVideo.made!(key, mp4)
        :ok

      {:error, reason} ->
        ShareVideo.failed(key, reason)
        {:cancel, reason}
    end
  rescue
    error ->
      ShareVideo.failed(key, :render_failed)
      reraise error, __STACKTRACE__
  end

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
