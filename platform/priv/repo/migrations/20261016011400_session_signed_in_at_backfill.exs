defmodule Autolaunch.Repo.Migrations.SessionSignedInAtBackfill do
  @moduledoc """
  A sign-in already bound counts from its last refresh, the closest record of it.

  Hand-written; no resource changes. Batches of a thousand rows in primary-key
  order, each its own short transaction, so no lock on session_authorities
  outlasts one batch while page reads wait at most five seconds for one.
  """

  use Ecto.Migration

  import Ecto.Query

  require Logger

  @disable_ddl_transaction true
  @disable_migration_lock true
  @batch_size 1_000

  def up, do: backfill(<<0::128>>)

  # Removing the column (`SessionSignedInAt.down/0`) removes what this wrote.
  def down, do: :ok

  defp backfill(after_id) do
    case repo().all(unfilled(after_id), prefix: prefix(), log: false) do
      [] ->
        :ok

      ids ->
        {count, _rows} =
          from(row in "session_authorities",
            where: row.id in ^ids and is_nil(row.signed_in_at),
            update: [set: [signed_in_at: row.updated_at]]
          )
          |> repo().update_all([], prefix: prefix(), log: false)

        Logger.info("session_authorities: filled signed_in_at on #{count} bound rows")
        backfill(List.last(ids))
    end
  end

  defp unfilled(after_id) do
    from(row in "session_authorities",
      where: row.id > ^after_id,
      where: not is_nil(row.human_account_id) and is_nil(row.signed_in_at),
      order_by: [asc: row.id],
      limit: @batch_size,
      select: row.id
    )
  end
end
