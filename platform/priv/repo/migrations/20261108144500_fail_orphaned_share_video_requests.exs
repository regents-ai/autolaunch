defmodule Autolaunch.Repo.Migrations.FailOrphanedShareVideoRequests do
  @moduledoc """
  Marks failed the share video requests left queued with no job behind them.
  A render cut off by a stopped machine had one try only, so Lifeline discarded
  its job and the request stayed queued, counted ahead of every later video.
  Renders now get a second try (`Autolaunch.ShareVideoRequest`), so none is
  left that way again.

  A queued request is failed only when no unfinished render job names it and
  it is more than an hour old, so a request still waiting its turn, or being
  rendered, is left alone. `updated_at` is left as it was, so asking for the
  video again makes a new one at once instead of reporting a failure moments
  old. No row is deleted.

  Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  def up do
    # Render jobs the release before queued carry one try in their own rows;
    # they get the second try too, so one cut off by this release's own
    # switchover is handed back by Lifeline and made again.
    execute ~s"""
    UPDATE "#{prefix()}".oban_jobs
    SET max_attempts = 2
    WHERE worker = 'Autolaunch.ShareVideoRequest.Workers.Render'
    AND state IN ('available', 'scheduled', 'executing', 'retryable')
    AND max_attempts < 2
    """

    execute ~s"""
    UPDATE "#{prefix()}".share_video_requests AS request
    SET state = 'failed'
    WHERE request.state = 'queued'
    AND request.inserted_at < (now() AT TIME ZONE 'utc') - interval '1 hour'
    AND NOT EXISTS (
      SELECT 1 FROM "#{prefix()}".oban_jobs AS job
      WHERE job.worker = 'Autolaunch.ShareVideoRequest.Workers.Render'
      AND job.state IN ('available', 'scheduled', 'executing', 'retryable')
      AND job.args -> 'primary_key' ->> 'id' = request.id::text
    )
    """
  end

  def down, do: :ok
end
