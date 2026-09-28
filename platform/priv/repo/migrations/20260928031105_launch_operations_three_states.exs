defmodule Autolaunch.Repo.Migrations.LaunchOperationsThreeStates do
  @moduledoc """
  A saved launch review now ends in one of three states: prepared, chain
  verified or cancelled. The retired `expired` and `invalidated` states were
  both a review that was never sent, so their rows become `cancelled`. A row
  with no reason keeps its old state as the reason. No row is deleted.

  Hand-written; the attribute change needs no generated migration.
  """

  use Ecto.Migration

  def up do
    # The tables live in the schema the migration runs in, which is not `public`
    # in production, so the hand-written SQL names it explicitly.
    for table <- ["launch_operations", "stock_launch_operations"] do
      execute ~s"""
      UPDATE "#{prefix()}".#{table}
      SET state = 'cancelled', reason = COALESCE(reason, state)
      WHERE state IN ('expired', 'invalidated')
      """
    end
  end

  def down, do: :ok
end
