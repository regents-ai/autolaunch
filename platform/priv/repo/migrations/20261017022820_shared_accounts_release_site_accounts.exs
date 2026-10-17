defmodule Autolaunch.Repo.Migrations.SharedAccountsReleaseSiteAccounts do
  @moduledoc """
  First of six: Autolaunch's records stop pointing at its own copy of each
  account (`human_accounts`), so they can point at the person's shared Regent
  account (`regent_names.platform_human_users`) instead.

  Before changing anything it checks, under this migration's transaction, that
  every person with an Autolaunch account has a shared account (matched by
  Privy ID), that the two records that name an account without a foreign key
  (`launch_discoveries.creator_human_account_id` and
  `robinhood_launch_reviews.human_account_id`) name one that exists, and that
  no Autolaunch account holds a name, picture or World ID that the move would
  lose (nothing on this site ever wrote them). If any check fails it stops with
  the count and changes nothing.

  Then it drops the eleven foreign keys to `human_accounts`. The data moves in
  `SharedAccountsMarkSiteIds` and `SharedAccountsMapToSharedIds`; the new keys
  come in `SharedAccounts` and are checked in `SharedAccountsValidate`;
  `DropHumanAccounts` removes the copy.

  The site must not be serving while these six run: the release before this one
  reads these columns as Autolaunch account numbers.
  """

  use Ecto.Migration

  @foreign_keys [
    {"launch_draft_images", "human_account_id", "RESTRICT"},
    {"auctions", "creator_human_account_id", "NO ACTION"},
    {"x_connections", "human_account_id", "CASCADE"},
    {"session_authorities", "human_account_id", "RESTRICT"},
    {"linked_identities", "human_account_id", "NO ACTION"},
    {"launch_operations", "human_account_id", "RESTRICT"},
    {"stock_launch_operations", "human_account_id", "RESTRICT"},
    {"stock_launch_draft_images", "human_account_id", "RESTRICT"},
    {"stock_launch_drafts", "human_account_id", "RESTRICT"},
    {"account_ens_identities", "human_account_id", "NO ACTION"},
    {"launch_drafts", "human_account_id", "NO ACTION"}
  ]

  # A page read waits at most five seconds for these tables, so the change gives
  # up after two rather than queue behind a long transaction; run migrate again.
  def up do
    refuse_unless_complete!()
    execute "SET LOCAL lock_timeout = '2s'"

    for {table, column, _on_delete} <- @foreign_keys do
      drop constraint(table, "#{table}_#{column}_fkey")
    end
  end

  def down do
    execute "SET LOCAL lock_timeout = '2s'"

    for {table, column, on_delete} <- @foreign_keys do
      execute """
      ALTER TABLE "#{prefix()}"."#{table}"
        ADD CONSTRAINT "#{table}_#{column}_fkey" FOREIGN KEY ("#{column}")
        REFERENCES "#{prefix()}"."human_accounts"("id") ON DELETE #{on_delete}
      """
    end
  end

  defp refuse_unless_complete! do
    checks = [
      {"people with an Autolaunch account and no shared Regent account",
       """
       SELECT count(*) FROM "#{prefix()}".human_accounts h
       WHERE NOT EXISTS (
         SELECT 1 FROM regent_names.platform_human_users p
         WHERE p.privy_user_id = h.privy_user_id
       )
       """},
      {"Autolaunch accounts holding a name, picture or World ID",
       """
       SELECT count(*) FROM "#{prefix()}".human_accounts
       WHERE display_name IS NOT NULL OR avatar IS NOT NULL
          OR world_human_id IS NOT NULL OR world_verified_at IS NOT NULL
       """},
      {"launch discoveries naming an Autolaunch account that does not exist",
       """
       SELECT count(*) FROM "#{prefix()}".launch_discoveries d
       WHERE d.creator_human_account_id IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM "#{prefix()}".human_accounts h WHERE h.id = d.creator_human_account_id
       )
       """},
      {"Robinhood launch reviews naming an Autolaunch account that does not exist",
       """
       SELECT count(*) FROM "#{prefix()}".robinhood_launch_reviews r
       WHERE NOT EXISTS (
         SELECT 1 FROM "#{prefix()}".human_accounts h WHERE h.id = r.human_account_id
       )
       """}
    ]

    failures =
      for {label, sql} <- checks,
          %{rows: [[count]]} = repo().query!(sql, [], log: false),
          count > 0,
          do: "#{count} #{label}"

    if failures != [] do
      raise "Nothing was changed: " <> Enum.join(failures, "; ")
    end
  end
end
