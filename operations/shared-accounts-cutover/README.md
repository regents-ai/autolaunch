# Shared-account cutover

The cutover stops Autolaunch keeping its own copy of each account
(`autolaunch_app.human_accounts`). A person who has only ever signed in on
Autolaunch first gets the shared Regent account (`regent_names.platform_human_users`)
a first sign-in on a site using the shared table writes. Then every record that
names a person moves to that person's shared account, matched by Privy ID, and
the copy is dropped. Six migrations do it:

| Migration | What it does | Transaction |
| --- | --- | --- |
| `20261017022820_shared_accounts_release_site_accounts` | Refuses, changing nothing, unless every person without a shared account holds wallets as a sign-in records them, no copy holds a name, picture or World ID, and the two unkeyed columns name real accounts; then creates the shared account of each person who has none, records every person and whether their account was created in `autolaunch_app.shared_accounts_cutover`, and drops the eleven keys to the copy | one, `lock_timeout` 2s |
| `20261017022821_shared_accounts_mark_site_ids` | Negates every Autolaunch account number in the thirteen columns | batches of 1,000 |
| `20261017022822_shared_accounts_map_to_shared_ids` | Turns each negated number into the shared account number by Privy ID; stops if any is left | batches of 1,000 |
| `20261017022823_shared_accounts` | Adds the eleven keys to the shared table, `NOT VALID` | one, `lock_timeout` 2s |
| `20261017022824_shared_accounts_validate` | Validates them without blocking sign-ins on other sites | none |
| `20261017022825_drop_human_accounts` | Drops the copy | one, `lock_timeout` 2s |

Each step can be run again after a failure. The site must not serve while
they run: the release before the cutover reads these columns as Autolaunch account numbers, and after the
move the same number can name a different person.

A created shared account holds exactly what `register_verified` writes at a
first sign-in (ash-template's `AshTemplate.Accounts.HumanAccount`, the same
action in Autolaunch's own resource): the Privy ID, the signed-in wallet and the
wallet list as Autolaunch holds them, and created and updated times of now.
Every other column keeps the table's default, as at sign-in. A shared account
that already exists is never written. As at a first sign-in, Points' trigger on
the shared table records each new account's wallets in
`regent_points.wallet_snapshots`. The rest of a sign-in (ENS name, linked
socials, Credits waiting under a wallet) happens at the person's next sign-in,
as it would have.

Rehearsed on local copies shaped like production (people from other sites in
the shared table, shared numbers running opposite to Autolaunch's, 22 people
already shared and 94 not): up, down and up, through the release's own
`migrate/0` and `rollback/1`, every record named the same person by Privy ID,
the 94 accounts were created and then removed, and no other shared account
changed. A run stopped by a lock timeout in the first migration created nothing;
a run killed midway through the move finished when run again; a sign-in
elsewhere during the first migration kept its own account. 116 people and 338
records took about a second (`/Users/sean/Documents/regent/artifacts/autolaunch-accounts94-2026-10-18/`).

## Steps

Needs Sean's named go: it changes production data, and `human_accounts` is on
the protected list.

1. Build the cutover image from a `git archive` export as the release procedure
   says, and run the read-only `pending-migrations` on its digest. Expect
   exactly the six versions above.
2. Read-only checks: run `checks-before.sql` against `regents_prod`
   (`psql -v migration_login="'<migrations login>'" -f checks-before.sql`).
   Check 1's `wallets_not_as_signed_in` and checks 2 and 3 must print 0, and
   check 5 must print true seven times. Check 1's `to_create` is how many shared
   accounts the cutover creates (94 on 18 Oct). Keep the output of checks 1
   and 6. If anything else prints, stop: nothing has changed.
3. Stop the site: `fly scale count 0 -a autolaunch-sh`, and confirm with
   `fly status -a autolaunch-sh` that no machine is running.
4. Migrate on a one-off machine with the cutover digest:
   `fly machine run <image@sha256> /app/bin/migrate -a autolaunch-sh-migrations --rm --restart no --region iad --vm-memory 1024 --env AUTOLAUNCH_DEPLOYMENT_ROLE=production`,
   then `fly logs -a autolaunch-sh-migrations --no-tail`. Expect the six
   `== Migrated` lines, one `created N shared Regent accounts; M people already
   had one` line, and one `moved N account numbers` line per column.
   If the first migration refuses, its message names the counts and nothing
   changed: start the previous release again with `fly scale count 1 -a autolaunch-sh`.
   A lock timeout or lost connection: run the same command again.
5. Read-only checks: run `checks-after.sql`. Expect 6, null, `11|11`; check 4
   with check 1's `people` and `people_digest`, 0 people with no shared account,
   and check 1's `to_create` and `to_create_digest` (both differ only if one of
   those people signed in on another site in between, and so kept the account
   that sign-in wrote); and the thirteen digest lines identical to check 6 of
   step 2.
6. Deploy the cutover from the folder holding `fly.toml` and `deployment/`:
   `fly deploy -c fly.toml --image <image@sha256> --strategy immediate`, then
   `fly scale count 1 -a autolaunch-sh` if no machine started. The health
   endpoint names the cutover commit.
7. Live checks: sign in on autolaunch.sh and open `/account`; a signed-in
   page shows the same account and drafts as before; an agent paired with
   someone who never signed in on Autolaunch gets 200 from
   `GET /api/agents/v1/me` and `GET /api/agent/v1/drafts/revstake`.

## Rollback

Every Regent site shares `regents_prod`, so the way back is the migrations'
own down steps, never a database restore. With the site stopped
(`fly scale count 0 -a autolaunch-sh`), on a one-off machine with the **cutover**
digest:

`fly machine run <cutover image@sha256> /app/bin/autolaunch eval 'Autolaunch.Release.rollback(20261017022820)' -a autolaunch-sh-migrations --rm --restart no --region iad --vm-memory 1024 --env AUTOLAUNCH_DEPLOYMENT_ROLE=production --env AUTOLAUNCH_RELEASE_COMMAND=migrate`

then deploy the previous release's image. Going down recreates `human_accounts` with one row
for every person on `shared_accounts_cutover` and every person a record names,
numbered as their shared account and holding its wallets, moves every record
back by Privy ID, and last removes exactly the shared accounts the cutover
created (those `shared_accounts_cutover` marks created) and nothing else;
`checks-before.sql` then prints the same checks 1 and 6 as before the move,
when nobody has signed in or written a record in between.

Three things about that last step:

- The shared account table is on `regents_prod`'s protected list, which
  refuses deletes. Sean lifts it for this one step, or the rollback stops
  there: every record is already back on `human_accounts` (without the eleven
  keys to it, which this step adds back), the previous release runs, and the
  created accounts stay.
- If another site has since attached its own records to a created account,
  its key refuses the delete and the step stops, changing nothing in it.
- Points never deletes a wallet record, so the one each created account got
  stays in `regent_points.wallet_snapshots`.
