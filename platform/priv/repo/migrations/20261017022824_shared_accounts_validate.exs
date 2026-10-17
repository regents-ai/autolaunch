defmodule Autolaunch.Repo.Migrations.SharedAccountsValidate do
  @moduledoc """
  Fifth of six: checks every existing row against the shared account keys
  `SharedAccounts` added.

  Hand-written; no resource changes. `VALIDATE CONSTRAINT` outside a migration
  transaction takes only a SHARE UPDATE EXCLUSIVE lock on each table and a ROW
  SHARE lock on the shared account table, so sign-ins on every Regent site go
  on while the rows are read.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @foreign_keys [
    {"launch_draft_images", "human_account_id"},
    {"auctions", "creator_human_account_id"},
    {"x_connections", "human_account_id"},
    {"session_authorities", "human_account_id"},
    {"linked_identities", "human_account_id"},
    {"launch_operations", "human_account_id"},
    {"stock_launch_operations", "human_account_id"},
    {"stock_launch_draft_images", "human_account_id"},
    {"stock_launch_drafts", "human_account_id"},
    {"account_ens_identities", "human_account_id"},
    {"launch_drafts", "human_account_id"}
  ]

  def up do
    for {table, column} <- @foreign_keys do
      execute ~s(ALTER TABLE "#{prefix()}"."#{table}" VALIDATE CONSTRAINT "#{table}_#{column}_fkey")
    end
  end

  # A validated key cannot be made unvalidated again; dropping it
  # (`SharedAccounts.down/0`) is the way back.
  def down, do: :ok
end
