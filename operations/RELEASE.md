# Releasing autolaunch.sh

Two steps every release of the site follows, besides building, checking and deploying it.
[RELEASES.md](../RELEASES.md) records which Fly release carried which commit, and
[CHANGELOG.md](../CHANGELOG.md) says what people and agents noticed.

## Before a table is deleted

Before any release deletes a table, whether a migration drops it or a step empties it:

1. Find the table's last write.
2. Find the Fly Managed Postgres backup taken after that write, and write its backup id in the
   release's evidence.

No backup id, no delete.

## After a lock on a protected table is lifted

Protected tables (listed in `regent_guard.protected_tables`) refuse being emptied, having rows
deleted and being dropped. Only Sean lifts that lock.

Whenever a lock is lifted on one table, the release then runs a read-only check that every other
guard is still in place: every other listed table still refuses being emptied, having rows deleted
and being dropped. The check reads production, so it runs only with Sean's allow naming it.
