defmodule Autolaunch.Repo.Migrations.SweepAfterSettlementSwitch do
  @moduledoc """
  Runs again the two clean-ups of the settlement-states release, for rows the
  machines of the release before it wrote while both ran at once:

    * a share video request left queued with no unfinished render job and over
      an hour old is failed (render jobs still waiting get their second try
      first), keeping its `updated_at`;
    * a launch review saved as cancelled becomes prepared.

  No row is deleted. Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  def up do
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

    for table <- ["launch_operations", "stock_launch_operations"] do
      execute ~s"""
      UPDATE "#{prefix()}".#{table}
      SET state = 'prepared', terminal_at = NULL
      WHERE state = 'cancelled'
      """
    end
  end

  def down, do: :ok
end
