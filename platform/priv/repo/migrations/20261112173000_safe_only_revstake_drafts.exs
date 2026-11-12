defmodule Autolaunch.Repo.Migrations.SafeOnlyRevstakeDrafts do
  @moduledoc """
  Makes stored Revstake drafts and launch reviews canonical now that every
  treasury is a 2-of-3 Safe named by its address:

    * a draft whose treasury kind was a single key (`eoa`) or a contract has
      its treasury cleared, so its person enters a Safe's address; the rest of
      the draft stays, and the agent's mark on the cleared treasury goes too;
    * no draft's list of fields its agent set names the treasury kind;
    * no saved launch review's list of fields its agent set names it.

  The kind and the typed private-key warning stay in their columns, no longer
  declared, until the next release drops them: the machines of the release
  before this one still read them while both run.

  Each statement changes only rows still in an old shape, so it is safe on
  empty tables and safe to run twice. All three run in the migration's one
  transaction. Locks: each `UPDATE` takes a row-exclusive lock on its table,
  which lets reads and other writes carry on, and holds the rows it changes
  until the transaction commits, so a save to one of those drafts waits that
  long. Each table is read through once. No row is deleted, and a draft keeps
  its `updated_at`, since drafts are listed newest first.

  Hand-written; `Autolaunch.LaunchDraft` stops declaring the two columns.
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
