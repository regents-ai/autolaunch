defmodule AutolaunchWeb.ShareVideo.Render do
  @moduledoc """
  Makes the video an `Autolaunch.ShareVideoRequest` asks for, stores it in
  the request and marks the request ready. Once the made videos come to 5 GB,
  a new one is still made but not saved: it is handed over once and then let
  go. A video that cannot be made fails the render, and the trigger marks the
  request failed.

  Each video made reports what it took as `[:autolaunch, :share_video,
  :rendered]`: the milliseconds, the MP4's bytes and the most memory the BEAM
  held while it ran.
  """
  use Ash.Resource.Change

  alias Autolaunch.Actors.System
  alias AutolaunchWeb.Paths
  alias AutolaunchWeb.ShareVideo.{Film, Story}

  @bytes 5_000_000_000

  @doc "How many bytes of made videos the site saves; past it a video is made but not saved."
  def saved_bytes, do: @bytes

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &render/1)

  defp render(%{data: request} = changeset) do
    with {:ok, story} <- story(request),
         {:ok, mp4, measured} <- Film.render(story) do
      :telemetry.execute(
        [:autolaunch, :share_video, :rendered],
        Map.take(measured, [:ms, :bytes, :peak_bytes]),
        %{kind: kind(request)}
      )

      changeset
      |> Ash.Changeset.force_change_attribute(:mp4, mp4)
      |> Ash.Changeset.force_change_attribute(:saved, room?())
      |> Ash.Changeset.force_change_attribute(:state, :ready)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset, "share video #{request.key}: #{inspect(reason)}")
    end
  end

  defp room?, do: Autolaunch.share_video_room!(@bytes, actor: %System{})

  defp story(%{kind: :token} = request) do
    with {:ok, auction} <- auction(request),
         {:ok, auction, token} <- found(Paths.find_token(auction.token_symbol, auction.path_tail)),
         do: token_story(auction, token, request.wallet)
  end

  defp story(%{kind: :auction} = request) do
    with {:ok, auction} <- auction(request), do: Story.auction(auction, request.wallet)
  end

  defp auction(request) do
    case Autolaunch.get_listed_auction(request.auction_id, actor: nil, load: [:path_tail]) do
      {:ok, %{} = auction} -> {:ok, auction}
      _unlisted -> {:error, :not_found}
    end
  end

  defp found(:error), do: {:error, :not_found}
  defp found(found), do: found

  defp token_story(auction, token, nil), do: Story.token(auction, token)
  defp token_story(auction, token, wallet), do: Story.wallet(auction, token, wallet)

  defp kind(%{kind: :token, wallet: nil}), do: :token
  defp kind(%{kind: :token}), do: :wallet
  defp kind(%{kind: :auction, wallet: nil}), do: :auction
  defp kind(%{kind: :auction}), do: :auction_wallet
end
