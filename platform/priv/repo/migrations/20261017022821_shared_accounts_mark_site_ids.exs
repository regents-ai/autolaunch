defmodule Autolaunch.Repo.Migrations.SharedAccountsMarkSiteIds do
  @moduledoc """
  Second of six: every column that names an Autolaunch account number has it
  negated, so a number still to be moved (negative) can never be mistaken for a
  shared account number already moved (positive). `SharedAccountsMapToSharedIds`
  then turns each negative number into the person's shared account number.

  Splitting the move in two keeps each step safe to run again: this one only
  touches positive numbers, and it is recorded as done before the next begins,
  so no row is ever moved twice.

  Hand-written; no resource changes. Batches of a thousand rows, each its own
  short transaction, so no lock outlasts one batch.
  """

  use Ecto.Migration

  require Logger

  @disable_ddl_transaction true
  @disable_migration_lock true
  @batch_size 1_000

  @columns [
    {"account_ens_identities", "human_account_id"},
    {"auctions", "creator_human_account_id"},
    {"launch_discoveries", "creator_human_account_id"},
    {"launch_draft_images", "human_account_id"},
    {"launch_drafts", "human_account_id"},
    {"launch_operations", "human_account_id"},
    {"linked_identities", "human_account_id"},
    {"robinhood_launch_reviews", "human_account_id"},
    {"session_authorities", "human_account_id"},
    {"stock_launch_draft_images", "human_account_id"},
    {"stock_launch_drafts", "human_account_id"},
    {"stock_launch_operations", "human_account_id"},
    {"x_connections", "human_account_id"}
  ]

  def up, do: Enum.each(@columns, fn {table, column} -> negate(table, column, ">") end)

  def down, do: Enum.each(@columns, fn {table, column} -> negate(table, column, "<") end)

  defp negate(table, column, sign) do
    sql = """
    UPDATE "#{prefix()}"."#{table}" SET "#{column}" = -"#{column}"
    WHERE ctid IN (
      SELECT ctid FROM "#{prefix()}"."#{table}" WHERE "#{column}" #{sign} 0 LIMIT #{@batch_size}
    )
    """

    total = batches(sql, 0)
    Logger.info("#{table}.#{column}: negated #{total} account numbers")
  end

  defp batches(sql, total) do
    case repo().query!(sql, [], log: false) do
      %{num_rows: 0} -> total
      %{num_rows: count} -> batches(sql, total + count)
    end
  end
end
