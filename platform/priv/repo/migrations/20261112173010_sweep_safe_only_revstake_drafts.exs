defmodule Autolaunch.Repo.Migrations.SweepSafeOnlyRevstakeDrafts do
  @moduledoc """
  Runs again the clean-up of 20261112173000_safe_only_revstake_drafts, for
  rows the machines of the release before it wrote while both ran at once,
  before the next migration drops the treasury kind's columns:

    * a draft whose treasury kind is a single key (`eoa`) or a contract has
      its treasury cleared, and the agent's mark on it goes too;
    * no draft's or saved launch review's list of fields its agent set names
      the treasury kind.

  Each statement changes only rows still in an old shape, so it is safe on
  empty tables and safe to run twice. All three run in the migration's one
  transaction, each `UPDATE` taking a row-exclusive lock on its table and
  holding only the rows it changes until commit. No row is deleted, and a
  draft keeps its `updated_at`.

  Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  def up do
    execute ~s"""
    UPDATE "#{prefix()}".launch_drafts
    SET treasury = NULL,
        treasury_path = 'safe',
        eoa_acknowledgement = NULL,
        agent_set_fields = array_remove(array_remove(agent_set_fields, 'treasury'), 'treasury_path')
    WHERE treasury_path <> 'safe'
    """

    execute ~s"""
    UPDATE "#{prefix()}".launch_drafts
    SET agent_set_fields = array_remove(agent_set_fields, 'treasury_path')
    WHERE 'treasury_path' = ANY (agent_set_fields)
    """

    execute ~s"""
    UPDATE "#{prefix()}".launch_operations
    SET envelope = jsonb_set(
          envelope,
          '{facts,agent_set_fields}',
          (envelope #> '{facts,agent_set_fields}') - 'treasury_path'
        )
    WHERE (envelope #> '{facts,agent_set_fields}') ? 'treasury_path'
    """
  end

  def down, do: :ok
end
