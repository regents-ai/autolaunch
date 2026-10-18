defmodule Autolaunch.Repo.Migrations.SharedAccountsReleaseSiteAccounts do
  @moduledoc """
  First of six: Autolaunch's records stop pointing at its own copy of each
  account (`human_accounts`), so they can point at the person's shared Regent
  account (`regent_names.platform_human_users`) instead.

  Before changing anything it checks, under this migration's transaction, that
  every person with no shared account (matched by Privy ID) holds wallets as a
  sign-in records them, that the two records that name an account without a
  foreign key (`launch_discoveries.creator_human_account_id` and
  `robinhood_launch_reviews.human_account_id`) name one that exists, and that
  no Autolaunch account holds a name, picture or World ID that the move would
  lose (nothing on this site ever wrote them). If any check fails it stops with
  the count and changes nothing.

  Then it gives every person with no shared account the row a first sign-in
  writes (`register_verified` on the shared account resource, as in
  ash-template): their Privy ID, their signed-in wallet and their wallet list
  as Autolaunch holds them, and created and updated times of now. Every other
  column keeps the table's default, as at sign-in. A shared account that
  already exists is never written, and a person who gets one from a sign-in
  elsewhere while this runs keeps that one. `shared_accounts_cutover` records
  the shared account of every Autolaunch person and whether this migration
  created it: going down removes exactly the created ones, and
  `DropHumanAccounts` going down gives every person on it an Autolaunch account
  again.

  Last it drops the eleven foreign keys to `human_accounts`. The data moves in
  `SharedAccountsMarkSiteIds` and `SharedAccountsMapToSharedIds`; the new keys
  come in `SharedAccounts` and are checked in `SharedAccountsValidate`;
  `DropHumanAccounts` removes the copy.

  The site must not be serving while these six run: the release before this one
  reads these columns as Autolaunch account numbers.
  """

  use Ecto.Migration

  require Logger

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
  # Everything here is one transaction: a failure leaves no shared account
  # created and nothing recorded.
  def up do
    refuse_unless_complete!()
    execute "SET LOCAL lock_timeout = '2s'"

    create table(:shared_accounts_cutover, primary_key: false) do
      add :human_account_id, :bigint, primary_key: true
      add :created, :boolean, null: false
    end

    flush()
    create_missing_shared_accounts!()

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

    flush()
    remove_created_shared_accounts!()

    drop table(:shared_accounts_cutover)
  end

  # The columns and values `register_verified` writes at a first sign-in. The
  # Privy ID's unique key decides a race with a sign-in elsewhere, as it does
  # for that action's upsert.
  defp create_missing_shared_accounts! do
    %{num_rows: created} =
      repo().query!(
        """
        WITH created AS (
          INSERT INTO regent_names.platform_human_users
            (privy_user_id, wallet_address, wallet_addresses, created_at, updated_at)
          SELECT h.privy_user_id, h.wallet_address, h.wallet_addresses,
                 now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc'
          FROM "#{prefix()}".human_accounts h
          WHERE NOT EXISTS (
            SELECT 1 FROM regent_names.platform_human_users p
            WHERE p.privy_user_id = h.privy_user_id
          )
          ORDER BY h.id
          ON CONFLICT (privy_user_id) DO NOTHING
          RETURNING id
        )
        INSERT INTO "#{prefix()}".shared_accounts_cutover (human_account_id, created)
        SELECT id, true FROM created
        """,
        [],
        log: false
      )

    %{num_rows: existing} =
      repo().query!(
        """
        INSERT INTO "#{prefix()}".shared_accounts_cutover (human_account_id, created)
        SELECT p.id, false
        FROM "#{prefix()}".human_accounts h
        JOIN regent_names.platform_human_users p ON p.privy_user_id = h.privy_user_id
        WHERE NOT EXISTS (
          SELECT 1 FROM "#{prefix()}".shared_accounts_cutover c WHERE c.human_account_id = p.id
        )
        """,
        [],
        log: false
      )

    Logger.info("created #{created} shared Regent accounts; #{existing} people already had one")
  end

  defp remove_created_shared_accounts! do
    %{num_rows: removed} =
      repo().query!(
        """
        DELETE FROM regent_names.platform_human_users p
        USING "#{prefix()}".shared_accounts_cutover c
        WHERE c.created AND p.id = c.human_account_id
        """,
        [],
        log: false
      )

    Logger.info("removed the #{removed} shared Regent accounts this cutover created")
  end

  # A sign-in writes a wallet list of distinct lowercase addresses holding the
  # signed-in wallet (`RegentPrivy`); a person whose wallets are otherwise would
  # get a shared account no sign-in could have written.
  defp refuse_unless_complete! do
    checks = [
      {"people with no shared Regent account whose wallets are not as a sign-in records them",
       """
       SELECT count(*) FROM "#{prefix()}".human_accounts h
       WHERE NOT EXISTS (
         SELECT 1 FROM regent_names.platform_human_users p
         WHERE p.privy_user_id = h.privy_user_id
       )
       AND (
         h.wallet_address ~ '^0x[0-9a-f]{40}$'
         AND h.wallet_address = ANY (h.wallet_addresses)
         AND NOT EXISTS (
           SELECT 1 FROM unnest(h.wallet_addresses) w WHERE w IS NULL OR w !~ '^0x[0-9a-f]{40}$'
         )
         AND cardinality(h.wallet_addresses) =
           (SELECT count(DISTINCT w) FROM unnest(h.wallet_addresses) w)
       ) IS NOT TRUE
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
