# Autolaunch to-do

## Creator X accounts before activation

Checked 22 September 2026 by secret name only: the live app `autolaunch-sh` holds no
`X_OAUTH_CLIENT_ID` (nor `PRIVY_APP_ID`; the site is still the read-only prelaunch). Until an
X app is registered with the callback `https://autolaunch.sh/auth/x/callback` and its client id
is set, creators cannot add X accounts and no auction or token shows a creator link.

Robinhood launches name their creator by the launching wallet: the account whose signed-in
wallet it still is, when exactly one account's is. The launch itself required that wallet.

## Before the wallet-steps release (A02)

Noted 28 September 2026 from the ash-template chief's review.

- **Saved launch reviews keep three states.** This branch keeps `prepared`, `chain_verified` and
  `cancelled`. The migration `20260928031105_launch_operations_three_states` turns any `expired`
  or `invalidated` row into `cancelled`, keeping its old state as the reason when it had none; no
  row is deleted. It was run on a local copy seeded with both old states and every row read back
  in an allowed state. Before release, count production's rows by state (read-only, with the
  founder's go) and confirm no other state exists.
- **Four wallet-press tables are archived, then dropped.** `wallet_attempts`, `bid_operations`,
  `bid_settlement_operations` and `subject_wallet_operations` are no longer written. The founder
  chose (a) on 28 September 2026: export them to an archive file, then drop them. The migration
  `20260928033335_drop_wallet_press_tables` drops them (`wallet_attempts` first, since it holds the
  keys to the other three); it was run on a local copy and `mix ash.codegen --check` is clean.
  Before it runs in production, export all four tables to CSV files in a dated archive folder
  (read-only `\copy`, one file per table), then release.
