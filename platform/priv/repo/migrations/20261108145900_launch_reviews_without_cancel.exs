defmodule Autolaunch.Repo.Migrations.LaunchReviewsWithoutCancel do
  @moduledoc """
  Saved launch reviews no longer have a cancelled state. Cancelling never
  stopped a launch the chain showed from being listed, so the state only
  labelled a review its page had let go. Those reviews become `prepared`, as a
  review the chain has not shown is. The reason column the cancel wrote is
  dropped by the next release, once no machine still reads it. No row is
  deleted.

  Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  def up do
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
