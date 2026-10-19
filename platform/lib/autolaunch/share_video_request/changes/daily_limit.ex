defmodule Autolaunch.ShareVideoRequest.Changes.DailyLimit do
  @moduledoc """
  Holds the site to 1000 videos in any 24 hours.

  A person's request is counted inside its own write, after a transaction lock
  every person's request takes, so they are written one after another however
  many arrive at once: each counts every request committed before it. A
  video already queued is that queued request, so asking for it again is
  never held. A launch's own videos have no account and are always made,
  though they count.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Autolaunch.Actors.System
  alias Autolaunch.Repo
  alias Autolaunch.ShareVideoRequest

  @daily 1000

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &hold/1)

  defp hold(changeset) do
    if is_nil(Ash.Changeset.get_attribute(changeset, :human_account_id)),
      do: changeset,
      else: held(changeset)
  end

  defp held(changeset) do
    lock!()

    if made_today() < @daily or queued?(Ash.Changeset.get_attribute(changeset, :key)),
      do: changeset,
      else:
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Invalid.Unavailable.exception(
            resource: ShareVideoRequest,
            reason: :daily_limit
          )
        )
  end

  defp made_today do
    ShareVideoRequest
    |> Ash.Query.for_read(:made_today, %{}, actor: %System{})
    |> Ash.count!(actor: %System{})
  end

  defp queued?(key) do
    ShareVideoRequest
    |> Ash.Query.for_read(:queued, %{}, actor: %System{})
    |> Ash.Query.filter(key == ^key)
    |> Ash.exists?(actor: %System{})
  end

  # Held until the request's transaction ends.
  defp lock! do
    <<key::signed-64, _rest::binary>> = :crypto.hash(:sha256, "share_video_requests:daily")
    Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])
  end
end
