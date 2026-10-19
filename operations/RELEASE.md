# Releasing autolaunch.sh

Steps every release of the site follows, besides building, checking and deploying it.
[RELEASES.md](../RELEASES.md) records which Fly release carried which commit, and
[CHANGELOG.md](../CHANGELOG.md) says what people and agents noticed.

Every query below reads production. Each runs read-only, and only with Sean's allow
naming it.

## Every migration

Before a release that runs any migration:

1. Write the id of the latest Fly Managed Postgres backup in the release's evidence.
2. For each table the migration touches, write its row count in the evidence.

After the migration, write each of those tables' row counts again, beside the first.

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
and being dropped.

## This release: one queued request per share video

The migration `20261018232413_share_video_queued_once` adds a unique index on
`autolaunch_app.share_video_requests` (`key`, for rows still queued). It cannot be built while two
queued requests share a key. In order:

1. Write the latest Fly Managed Postgres backup id in the evidence.
2. Count the rows and write the count in the evidence:

   ```sql
   SELECT count(*) FROM autolaunch_app.share_video_requests;
   ```

3. Check for a video queued twice:

   ```sql
   SELECT key, count(*) FROM autolaunch_app.share_video_requests WHERE state = 'queued' GROUP BY key HAVING count(*) > 1;
   ```

   - No rows: continue.
   - Any row: stop, and say in one line "Stopped: a share video is queued twice, so the new index
     can't be built." Delete nothing, don't run it again, and report to the coordinator.

4. Migrate.
5. Count the rows again with the query in step 2 and write the count beside the first. The
   migration adds an index only, so the two counts match unless people asked for videos in
   between.
