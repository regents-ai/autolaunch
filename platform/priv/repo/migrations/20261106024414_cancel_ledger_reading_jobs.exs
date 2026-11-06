defmodule Autolaunch.Repo.Migrations.CancelLedgerReadingJobs do
  @moduledoc """
  Cancels the ledger's reading jobs that were running while the ledger's tables
  were dropped. The machine running them handed them back for another try, and
  no worker runs them now, so every try failed.
  """

  use Ecto.Migration

  def up do
    execute ~s"""
    UPDATE "#{prefix()}".oban_jobs
    SET state = 'cancelled', cancelled_at = (now() AT TIME ZONE 'utc')
    WHERE worker = 'Autolaunch.Indexer.ReadChain'
    AND state NOT IN ('completed', 'discarded', 'cancelled')
    """
  end

  def down, do: :ok
end
