defmodule Autolaunch.Repo.Migrations.FailOrphanedShareVideoRequests do
  @moduledoc """
  Marks failed the share video requests left queued with no job behind them.
  A render cut off by a stopped machine had one try only, so Lifeline discarded
  its job and the request stayed queued, counted ahead of every later video.
  Renders now get a second try (`Autolaunch.ShareVideoRequest`), so none is
  left that way again.

  A queued request more than an hour old has no live job: a render takes
  minutes and Lifeline hands a cut-off one back after twenty. `updated_at` is
  left as it was, so asking for the video again makes a new one at once
  instead of reporting a failure moments old. No row is deleted.

  Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  def up do
    execute ~s"""
    UPDATE "#{prefix()}".share_video_requests
    SET state = 'failed'
    WHERE state = 'queued'
    AND inserted_at < (now() AT TIME ZONE 'utc') - interval '1 hour'
    """
  end

  def down, do: :ok
end
