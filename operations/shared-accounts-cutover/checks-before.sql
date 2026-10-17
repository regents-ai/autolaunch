-- Read-only checks before the shared-account migrations (v144). Run against
-- regents_prod with any login that can read autolaunch_app and regent_names.
-- Nothing here writes, and no Privy ID or wallet leaves the database: the last
-- query prints counts and one digest per table. Keep its output; the same
-- digests must come back from checks-after.sql.
-- Replace :migration_login with the login the migrations app connects as
-- (psql -v migration_login="'name'").
BEGIN TRANSACTION READ ONLY;

-- 1. People with an Autolaunch account and no shared Regent account. Must be 0.
SELECT count(*) AS no_shared_account
FROM autolaunch_app.human_accounts h
WHERE NOT EXISTS (
  SELECT 1 FROM regent_names.platform_human_users p WHERE p.privy_user_id = h.privy_user_id
);

-- 2. Values only Autolaunch's copy holds, which the move would lose. All must be 0.
SELECT count(*) FILTER (WHERE display_name IS NOT NULL) AS names,
       count(*) FILTER (WHERE avatar IS NOT NULL) AS pictures,
       count(*) FILTER (WHERE world_human_id IS NOT NULL OR world_verified_at IS NOT NULL) AS world_ids
FROM autolaunch_app.human_accounts;

-- 3. Records naming an Autolaunch account that does not exist, in the two
-- columns without a key. Both must be 0.
SELECT
  (SELECT count(*) FROM autolaunch_app.launch_discoveries d
   WHERE d.creator_human_account_id IS NOT NULL AND NOT EXISTS (
     SELECT 1 FROM autolaunch_app.human_accounts h WHERE h.id = d.creator_human_account_id)) AS discoveries,
  (SELECT count(*) FROM autolaunch_app.robinhood_launch_reviews r
   WHERE NOT EXISTS (
     SELECT 1 FROM autolaunch_app.human_accounts h WHERE h.id = r.human_account_id)) AS robinhood_reviews;

-- 4. For the record: people, and people whose wallets on Autolaunch's copy
-- differ from their shared account's (after the move the site shows the
-- shared account's).
SELECT count(*) AS people,
       count(*) FILTER (WHERE h.wallet_address IS DISTINCT FROM p.wallet_address
                           OR h.wallet_addresses::text[] IS DISTINCT FROM p.wallet_addresses::text[]) AS wallets_differ
FROM autolaunch_app.human_accounts h
JOIN regent_names.platform_human_users p USING (privy_user_id);

-- 5. The migrations login may read the shared account table and point keys at
-- it. Both must be true.
SELECT has_table_privilege(:migration_login, 'regent_names.platform_human_users', 'SELECT') AS can_read,
       has_table_privilege(:migration_login, 'regent_names.platform_human_users', 'REFERENCES') AS can_reference;

-- 6. Per table: rows, rows naming nobody, rows naming a missing account (must
-- be 0), and a digest of every row with the Privy ID of the person it names.
WITH named AS (
  SELECT 'account_ens_identities' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.account_ens_identities r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'auctions' AS tbl, r.id::text AS id, r.creator_human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.auctions r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.creator_human_account_id
  UNION ALL
  SELECT 'launch_discoveries' AS tbl, r.id::text AS id, r.creator_human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.launch_discoveries r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.creator_human_account_id
  UNION ALL
  SELECT 'launch_draft_images' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.launch_draft_images r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'launch_drafts' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.launch_drafts r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'launch_operations' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.launch_operations r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'linked_identities' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.linked_identities r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'robinhood_launch_reviews' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.robinhood_launch_reviews r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'session_authorities' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.session_authorities r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'stock_launch_draft_images' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.stock_launch_draft_images r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'stock_launch_drafts' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.stock_launch_drafts r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'stock_launch_operations' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.stock_launch_operations r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'x_connections' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.x_connections r LEFT JOIN autolaunch_app.human_accounts a ON a.id = r.human_account_id
)
SELECT tbl, count(*) AS rows, count(*) FILTER (WHERE nobody) AS naming_nobody,
       count(*) FILTER (WHERE NOT nobody AND who IS NULL) AS naming_a_missing_account,
       md5(string_agg(id || ':' || coalesce(who, 'nobody'), ',' ORDER BY id)) AS digest
FROM named GROUP BY tbl ORDER BY tbl;

COMMIT;
