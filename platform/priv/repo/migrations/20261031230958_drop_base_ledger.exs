defmodule Autolaunch.Repo.Migrations.DropBaseLedger do
  @moduledoc """
  Drops the Base log ledger's four tables. Revstake launches are now found by
  the factory's own launch count, as Memestock launches are
  (`Autolaunch.LaunchDiscovery.Discover`), so nothing reads or writes them.

  The ledger's waiting reading job is cancelled, since no worker runs it now,
  and a waiting Memestock discovery becomes the discovery of both launchpads.

  Hand-written; the ledger's resources are gone. `down` puts the tables back
  empty, in the shape they last had, so the release before this one can run
  again and read the chain from its start block.
  """

  use Ecto.Migration

  def up do
    execute ~s"""
    UPDATE "#{prefix()}".oban_jobs
    SET state = 'cancelled', cancelled_at = (now() AT TIME ZONE 'utc')
    WHERE worker = 'Autolaunch.Indexer.ReadChain'
    AND state IN ('available', 'scheduled', 'retryable')
    """

    execute ~s"""
    UPDATE "#{prefix()}".oban_jobs
    SET worker = 'Autolaunch.LaunchDiscovery.Workers.Discover'
    WHERE worker = 'Autolaunch.LaunchDiscovery.Workers.DiscoverMemestock'
    AND state IN ('available', 'scheduled', 'retryable')
    """

    drop table(:indexer_logs)
    drop table(:indexer_blocks)
    drop table(:indexer_cursors)
    drop table(:indexer_sources)
  end

  def down do
    create table(:indexer_blocks, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :block_number, :bigint, null: false
      add :block_hash, :text, null: false
      add :parent_hash, :text, null: false
      add :canonical, :boolean, null: false, default: true
      add :finalized, :boolean, null: false, default: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:indexer_blocks, [:chain_id, :block_hash],
             name: "indexer_blocks_unique_block_index"
           )

    create constraint(:indexer_blocks, :indexer_blocks_block_number_nonnegative,
             check: "block_number >= 0"
           )

    create constraint(:indexer_blocks, :indexer_blocks_finalized_is_canonical,
             check: "canonical or not finalized"
           )

    create index(:indexer_blocks, [:chain_id, :block_number],
             name: "indexer_blocks_canonical_height_index",
             unique: true,
             where: "canonical"
           )

    create index(:indexer_blocks, [:chain_id, :finalized, :block_number],
             name: "indexer_blocks_finalized_frontier_index"
           )

    create table(:indexer_cursors, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :next_block_to_fetch, :bigint, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:indexer_cursors, [:chain_id], name: "indexer_cursors_unique_chain_index")

    create constraint(:indexer_cursors, :indexer_cursors_next_block_nonnegative,
             check: "next_block_to_fetch >= 0"
           )

    create table(:indexer_logs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :block_hash, :text, null: false
      add :log_index, :bigint, null: false
      add :transaction_hash, :text, null: false
      add :transaction_index, :bigint, null: false
      add :address, :text, null: false
      add :topics, {:array, :text}, null: false
      add :data, :text, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :block_id,
          references(:indexer_blocks,
            column: :id,
            name: "indexer_logs_block_id_fkey",
            type: :uuid,
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:indexer_logs, [:chain_id, :block_hash, :log_index],
             name: "indexer_logs_unique_log_index"
           )

    create constraint(:indexer_logs, :indexer_logs_log_index_nonnegative, check: "log_index >= 0")

    create constraint(:indexer_logs, :indexer_logs_transaction_index_nonnegative,
             check: "transaction_index >= 0"
           )

    create table(:indexer_sources, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :address, :text, null: false
      add :start_block, :bigint, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:indexer_sources, [:chain_id, :address],
             name: "indexer_sources_unique_source_index"
           )

    create constraint(:indexer_sources, :indexer_sources_start_block_nonnegative,
             check: "start_block >= 0"
           )
  end
end
