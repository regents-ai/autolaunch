-- Read-only checks after the shared-account migrations, before the new
-- release takes traffic. Every digest must equal the one checks-before.sql
-- printed: every Autolaunch person has a shared Regent account, the ones
-- created hold the Privy ID and wallets Autolaunch held, and each record still
-- names the same person, now through the shared Regent account.
BEGIN TRANSACTION READ ONLY;

-- 1. The six migrations are recorded. Must be 6.
SELECT count(*) AS applied FROM autolaunch_app.schema_migrations
WHERE version BETWEEN 20261017022820 AND 20261017022825;

-- 2. Autolaunch's copy is gone. Must be null.
SELECT to_regclass('autolaunch_app.human_accounts') AS copy;

-- 3. Eleven keys point at the shared account table, all validated. Must be 11 and 11.
SELECT count(*) AS keys, count(*) FILTER (WHERE convalidated) AS validated
FROM pg_constraint
WHERE contype = 'f' AND confrelid = 'regent_names.platform_human_users'::regclass
  AND connamespace = 'autolaunch_app'::regnamespace;

-- 4. Every person who had an Autolaunch account, as the first migration
-- recorded them: how many (checks-before.sql check 1's people), how many it
-- created a shared account for (its to_create), how many have no shared
-- account (must be 0), and the two digests, which must equal check 1's
-- people_digest and to_create_digest.
SELECT count(*) AS people,
       count(*) FILTER (WHERE c.created) AS created,
       count(*) FILTER (WHERE p.id IS NULL) AS no_shared_account,
       md5(string_agg(p.privy_user_id, ',' ORDER BY p.privy_user_id)) AS people_digest,
       md5(string_agg(p.privy_user_id || ':' || p.wallet_address || ':' || array_to_string(p.wallet_addresses, ' '),
                      ',' ORDER BY p.privy_user_id) FILTER (WHERE c.created)) AS to_create_digest
FROM autolaunch_app.shared_accounts_cutover c
LEFT JOIN regent_names.platform_human_users p ON p.id = c.human_account_id;

-- 5. Per table, as before: the digests must match checks-before.sql check 6's.
WITH named AS (
  SELECT 'account_ens_identities' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.account_ens_identities r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'auctions' AS tbl, r.id::text AS id, r.creator_human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.auctions r LEFT JOIN regent_names.platform_human_users a ON a.id = r.creator_human_account_id
  UNION ALL
  SELECT 'launch_discoveries' AS tbl, r.id::text AS id, r.creator_human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.launch_discoveries r LEFT JOIN regent_names.platform_human_users a ON a.id = r.creator_human_account_id
  UNION ALL
  SELECT 'launch_draft_images' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.launch_draft_images r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'launch_drafts' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.launch_drafts r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'launch_operations' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.launch_operations r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'linked_identities' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.linked_identities r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'robinhood_launch_reviews' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.robinhood_launch_reviews r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'session_authorities' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.session_authorities r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'stock_launch_draft_images' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.stock_launch_draft_images r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'stock_launch_drafts' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.stock_launch_drafts r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'stock_launch_operations' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.stock_launch_operations r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
  UNION ALL
  SELECT 'x_connections' AS tbl, r.id::text AS id, r.human_account_id IS NULL AS nobody, a.privy_user_id AS who
  FROM autolaunch_app.x_connections r LEFT JOIN regent_names.platform_human_users a ON a.id = r.human_account_id
)
SELECT tbl, count(*) AS rows, count(*) FILTER (WHERE nobody) AS naming_nobody,
       count(*) FILTER (WHERE NOT nobody AND who IS NULL) AS naming_a_missing_account,
       md5(string_agg(id || ':' || coalesce(who, 'nobody'), ',' ORDER BY id)) AS digest
FROM named GROUP BY tbl ORDER BY tbl;

COMMIT;
