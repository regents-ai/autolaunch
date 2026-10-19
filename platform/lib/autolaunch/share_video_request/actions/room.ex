defmodule Autolaunch.ShareVideoRequest.Actions.Room do
  @moduledoc """
  Whether the made videos still held come to less than `bytes`. Sizes are
  read with `octet_length`, never the videos themselves.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Autolaunch.Actors.System
  alias Autolaunch.ShareVideoRequest

  @impl true
  def run(input, _opts, _context) do
    held =
      ShareVideoRequest
      |> Ash.Query.filter(not is_nil(mp4))
      |> Ash.sum!(:size, actor: %System{})

    {:ok, (held || 0) < input.arguments.bytes}
  end
end
