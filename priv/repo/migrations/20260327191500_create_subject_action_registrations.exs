defmodule Autolaunch.Repo.Migrations.CreateSubjectActionRegistrations do
  use Ecto.Migration

  def change do
    create table(:autolaunch_subject_action_registrations) do
      add :subject_id, :string, null: false
      add :action, :string, null: false
      add :owner_address, :string, null: false
      add :chain_id, :integer, null: false
      add :tx_hash, :string, null: false
      add :ingress_address, :string
      add :amount, :string
      add :status, :string, null: false, default: "pending"
      add :block_number, :integer
      add :error_code, :string
      add :error_message, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:autolaunch_subject_action_registrations, [:tx_hash],
             name: :autolaunch_subject_action_registrations_tx_hash_unique
           )

    create index(:autolaunch_subject_action_registrations, [:subject_id, :action, :owner_address],
             name: :autolaunch_subject_action_registrations_scope_index
           )
  end
end
