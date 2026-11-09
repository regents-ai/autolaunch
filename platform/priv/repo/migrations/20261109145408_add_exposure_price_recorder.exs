defmodule Autolaunch.Repo.Migrations.AddExposurePriceRecorder do
  @moduledoc """
  The After-hours price recorder's tables: one row per series it follows
  (`exposure_recordings`) and every transaction its wallet signed
  (`exposure_recorder_transactions`). Adds two tables; changes nothing else.
  """

  use Ecto.Migration

  def up do
    create table(:exposure_recordings, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :chain_id, :bigint, null: false
      add :series, :text, null: false
      add :state, :text, null: false, default: "running"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:exposure_recordings, [:chain_id, :series],
             name: "exposure_recordings_series_index"
           )

    create table(:exposure_recorder_transactions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :step, :text, null: false
      add :chain_id, :bigint, null: false
      add :signer, :text, null: false
      add :nonce, :bigint, null: false
      add :transaction_hash, :text, null: false
      add :raw_transaction, :text, null: false
      add :state, :text, null: false, default: "signed"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :recording_id,
          references(:exposure_recordings,
            column: :id,
            name: "exposure_recorder_transactions_recording_id_fkey",
            type: :uuid,
            prefix: "autolaunch_app",
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:exposure_recorder_transactions, [:chain_id, :signer, :nonce],
             name: "exposure_recorder_transactions_nonce_index"
           )

    create unique_index(:exposure_recorder_transactions, [:recording_id],
             name: "exposure_recorder_transactions_unsettled_index",
             where: "(state = 'signed')"
           )
  end

  def down do
    drop table(:exposure_recorder_transactions)
    drop table(:exposure_recordings)
  end
end
