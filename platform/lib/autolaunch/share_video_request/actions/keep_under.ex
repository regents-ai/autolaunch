defmodule Autolaunch.ShareVideoRequest.Actions.KeepUnder do
  @moduledoc """
  Deletes the oldest made videos until those left hold at most `bytes`: the
  newest are kept while their sizes, added up newest first, stay within it.
  Requests that hold no video are never touched.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Autolaunch.Actors.System
  alias Autolaunch.ShareVideoRequest

  @impl true
  def run(input, _opts, _context) do
    stored = Ash.read!(ShareVideoRequest, action: :stored, actor: %System{})
    totals = Enum.scan(stored, 0, &(&1.size + &2))

    over =
      for {video, total} <- Enum.zip(stored, totals), total > input.arguments.bytes, do: video.id

    ShareVideoRequest
    |> Ash.Query.filter(id in ^over)
    |> Ash.bulk_destroy!(:destroy, %{}, actor: %System{}, strategy: :stream)

    :ok
  end
end
