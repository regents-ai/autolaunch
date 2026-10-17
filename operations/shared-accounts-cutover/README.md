# Shared-account cutover (v146)

v146 stops Autolaunch keeping its own copy of each account
(`autolaunch_app.human_accounts`). Every record that names a person moves to
that person's shared Regent account (`regent_names.platform_human_users`),
matched by Privy ID, and the copy is dropped. Six migrations do it:

| Migration | What it does | Transaction |
| --- | --- | --- |
| `20261017022820_shared_accounts_release_site_accounts` | Refuses, changing nothing, unless every person has a shared account, no copy holds a name, picture or World ID, and the two unkeyed columns name real accounts; then drops the eleven keys to the copy | one, `lock_timeout` 2s |
| `20261017022821_shared_accounts_mark_site_ids` | Negates every Autolaunch account number in the thirteen columns | batches of 1,000 |
| `20261017022822_shared_accounts_map_to_shared_ids` | Turns each negated number into the shared account number by Privy ID; stops if any is left | batches of 1,000 |
| `20261017022823_shared_accounts` | Adds the eleven keys to the shared table, `NOT VALID` | one, `lock_timeout` 2s |
| `20261017022824_shared_accounts_validate` | Validates them without blocking sign-ins on other sites | none |
| `20261017022825_drop_human_accounts` | Drops the copy | one, `lock_timeout` 2s |

Each step can be run again after a failure. The site must not serve while
they run: v144 reads these columns as Autolaunch account numbers, and after the
move the same number can name a different person.

Rehearsed on local copies shaped like production (people from other sites in
the shared table, shared numbers running opposite to Autolaunch's, one person
whose wallet changed elsewhere): up, down and up, through the release's own
`migrate/0` and `rollback/1`, every record named the same person by Privy ID.
40 people and 321 records took under 0.1 seconds; 5,000 people and 40,000
records took 0.7 seconds.

## Steps

Needs Sean's named go: it changes production data, and `human_accounts` is on
the protected list.

1. Build the v146 image from a `git archive` export as the release procedure
   says, and run the read-only `pending-migrations` on its digest. Expect
   exactly the six versions above.
2. Read-only checks: run `checks-before.sql` against `regents_prod`
   (`psql -v migration_login="'<migrations login>'" -f checks-before.sql`).
   Checks 1 to 3 must print 0, check 5 `t|t`. Keep the output of check 6.
   If anything else prints, stop: nothing has changed.
3. Stop the site: `fly scale count 0 -a autolaunch-sh`, and confirm with
   `fly status -a autolaunch-sh` that no machine is running.
4. Migrate on a one-off machine with the v146 digest:
   `fly machine run <image@sha256> /app/bin/migrate -a autolaunch-sh-migrations --rm --restart no --region iad --vm-memory 1024 --env AUTOLAUNCH_DEPLOYMENT_ROLE=production`,
   then `fly logs -a autolaunch-sh-migrations --no-tail`. Expect the six
   `== Migrated` lines and one `moved N account numbers` line per column.
   If the first migration refuses, its message names the counts and nothing
   changed: start v144 again with `fly scale count 1 -a autolaunch-sh`.
   A lock timeout or lost connection: run the same command again.
5. Read-only checks: run `checks-after.sql`. Expect 6, null, `11|11`, and the
   thirteen digest lines identical to check 6 of step 2.
6. Deploy v146 from the folder holding `fly.toml` and `deployment/`:
   `fly deploy -c fly.toml --image <image@sha256> --strategy immediate`, then
   `fly scale count 1 -a autolaunch-sh` if no machine started. The health
   endpoint names the v146 commit.
7. Live checks: sign in on autolaunch.sh and open `/account`; a signed-in
   page shows the same account and drafts as before; an agent paired with
   someone who never signed in on Autolaunch gets 200 from
   `GET /api/agents/v1/me` and `GET /api/agent/v1/drafts/revstake`.

## Rollback

Every Regent site shares `regents_prod`, so the way back is the migrations'
own down steps, never a database restore. With the site stopped
(`fly scale count 0 -a autolaunch-sh`), on a one-off machine with the **v146**
digest:

`fly machine run <v146 image@sha256> /app/bin/autolaunch eval 'Autolaunch.Release.rollback(20261017022820)' -a autolaunch-sh-migrations --rm --restart no --region iad --vm-memory 1024 --env AUTOLAUNCH_DEPLOYMENT_ROLE=production --env AUTOLAUNCH_RELEASE_COMMAND=migrate`

then deploy v144's image. Going down recreates `human_accounts` with one row
per person a record names, numbered as their shared account and holding its
wallets, and moves every record back by Privy ID; `checks-before.sql`'s check 6
then prints the same digests as before the move.
