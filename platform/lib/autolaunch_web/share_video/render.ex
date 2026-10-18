defmodule AutolaunchWeb.ShareVideo.Render do
  @moduledoc """
  Makes the video an `Autolaunch.ShareVideoRequest` asks for, keeps it
  (`AutolaunchWeb.ShareVideo`) and marks the request ready. A video that
  cannot be made fails the render, and the trigger marks the request failed.

  Each video made reports what it took as `[:autolaunch, :share_video,
  :rendered]`: the milliseconds, the MP4's bytes and the most memory the BEAM
  held while it ran.
  """
  use Ash.Resource.Change

  alias AutolaunchWeb.{Paths, ShareVideo}
  alias AutolaunchWeb.ShareVideo.{Film, Story}

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &render/1)

  defp render(%{data: request} = changeset) do
    with {:ok, story, address} <- story(request),
         {:ok, mp4, measured} <-
           Film.render(story, String.replace(address, ~r{\Ahttps?://}, "")) do
      :telemetry.execute(
        [:autolaunch, :share_video, :rendered],
        Map.take(measured, [:ms, :bytes, :peak_bytes]),
        %{kind: kind(request)}
      )

      :ok = ShareVideo.made!(request.key, mp4)
      Ash.Changeset.force_change_attribute(changeset, :state, :ready)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset, "share video #{request.key}: #{inspect(reason)}")
    end
  end

  # The story with the address the video's band names: the token's page, or
  # the auction's while it runs.
  defp story(%{kind: :token} = request) do
    with {:ok, auction} <- auction(request),
         {:ok, auction, token} <- found(Paths.find_token(auction.token_symbol, auction.path_tail)),
         {:ok, story} <- token_story(auction, token, request.wallet),
         do: {:ok, story, Paths.token_url(auction)}
  end

  defp story(%{kind: :auction} = request) do
    with {:ok, auction} <- auction(request),
         {:ok, story} <- Story.auction(auction, request.wallet),
         do: {:ok, story, Paths.auction_url(auction)}
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
