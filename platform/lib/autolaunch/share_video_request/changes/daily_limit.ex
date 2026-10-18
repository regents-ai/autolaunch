defmodule Autolaunch.ShareVideoRequest.Changes.DailyLimit do
  @moduledoc """
  Holds an account to three new videos of its own in any 24 hours.

  The count is taken inside the request's own write, after a transaction lock
  held for that account, so an account's requests are written one after
  another however many arrive at once: each counts every request committed
  before it. A video the account already asked for today never counts again.
  The launch's own videos have no account and are never held.
  """
  use Ash.Resource.Change

  alias Autolaunch.Actors.System
  alias Autolaunch.Repo
  alias Autolaunch.ShareVideoRequest

  @daily 3

  @doc "How many videos of its own an account may make in any 24 hours."
  def daily, do: @daily

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &hold/1)

  defp hold(changeset) do
    case Ash.Changeset.get_attribute(changeset, :human_account_id) do
      nil -> changeset
      account -> hold(changeset, account)
    end
  end

  defp hold(changeset, account) do
    lock!(account)
    key = Ash.Changeset.get_attribute(changeset, :key)
    made = MapSet.new(Autolaunch.share_videos_made_today!(account, actor: %System{}), & &1.key)

    if MapSet.member?(made, key) or MapSet.size(made) < @daily,
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

  # Held until the request's transaction ends.
  defp lock!(account) do
    <<key::signed-64, _rest::binary>> = :crypto.hash(:sha256, "share_video_requests:#{account}")
    Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])
  end
end
