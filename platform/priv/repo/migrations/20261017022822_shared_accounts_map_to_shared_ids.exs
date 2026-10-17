defmodule Autolaunch.Repo.Migrations.SharedAccountsMapToSharedIds do
  @moduledoc """
  Third of six: each Autolaunch account number that `SharedAccountsMarkSiteIds`
  negated becomes the number of the same person's shared Regent account, the
  one with the same Privy ID. Only negative numbers are moved, so running this
  again moves only what is left. It finishes by checking that nothing is left;
  `SharedAccountsReleaseSiteAccounts` already refused to start unless every
  person had a shared account.

  Going down turns each shared account number back into the negated number of
  the Autolaunch account with the same Privy ID.

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

  def up do
    for {table, column} <- @columns do
      move(table, column,
        from: "-r.\"#{column}\" = h.id",
        to: "p.id",
        pending: "\"#{column}\" < 0"
      )
    end
  end

  def down do
    for {table, column} <- @columns do
      move(table, column,
        from: "r.\"#{column}\" = p.id",
        to: "-h.id",
        pending: "\"#{column}\" > 0"
      )
    end
  end

  # Moves every pending row whose person has both accounts, then checks none
  # is left behind.
  defp move(table, column, from: from, to: to, pending: pending) do
    mapped = """
    FROM "#{prefix()}"."#{table}" r,
         "#{prefix()}".human_accounts h,
         regent_names.platform_human_users p
    WHERE p.privy_user_id = h.privy_user_id AND #{from} AND r.#{pending}
    """

    sql = """
    UPDATE "#{prefix()}"."#{table}" t SET "#{column}" = m.account_id
    FROM (SELECT r.ctid AS row_ctid, #{to} AS account_id #{mapped} LIMIT #{@batch_size}) m
    WHERE t.ctid = m.row_ctid
    """

    total = batches(sql, 0)

    %{rows: [[left]]} =
      repo().query!(
        ~s{SELECT count(*) FROM "#{prefix()}"."#{table}" WHERE #{pending}},
        [],
        log: false
      )

    if left > 0 do
      raise "#{table}.#{column}: #{left} rows name an account with no match by Privy ID; " <>
              "#{total} were moved and the rest left as they were"
    end

    Logger.info("#{table}.#{column}: moved #{total} account numbers")
  end

  defp batches(sql, total) do
    case repo().query!(sql, [], log: false) do
      %{num_rows: 0} -> total
      %{num_rows: count} -> batches(sql, total + count)
    end
  end
end
