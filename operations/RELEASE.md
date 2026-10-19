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

## This release: stored share videos

The migration `20261019034325_add_share_video_storage` adds two columns to
`autolaunch_app.share_video_requests`, `mp4` (binary, empty) and `saved` (boolean, true), and one
index (`human_account_id`, `auction_id`, `kind`, `inserted_at`). It deletes nothing. In order:

1. Write the latest Fly Managed Postgres backup id in the evidence, and the database's size
   (read only, Sean's "go read-only space check"):

   ```sql
   SELECT pg_size_pretty(pg_database_size(current_database()));
   ```

2. Count the rows and write the count in the evidence:

   ```sql
   SELECT count(*) FROM autolaunch_app.share_video_requests;
   ```

3. Migrate.
4. Count the rows again with the query in step 2 and write the count beside the first. It
   matches unless people asked for videos in between: the hourly cleanup only lets go of the
   bytes of saved videos a day old and never removes a request.
5. Once a video has been made on the live site, check it was saved:

   ```sql
   SELECT state, saved, count(*), sum(octet_length(mp4)) FROM autolaunch_app.share_video_requests GROUP BY 1, 2;
   ```

   Ready rows show `saved` true and a size of about 200 to 300 KB each.
