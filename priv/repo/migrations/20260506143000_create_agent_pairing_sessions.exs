defmodule Autolaunch.Repo.Migrations.CreateAgentPairingSessions do
  use Ecto.Migration

  def change do
    create table(:autolaunch_agent_pairing_sessions) do
      add :session_id, :string, null: false
      add :human_user_id, references(:autolaunch_human_users, on_delete: :restrict), null: false
      add :privy_user_id, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :pairing_code_hash, :string, null: false
      add :challenge_nonce, :string, null: false
      add :challenge_message, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :agent_wallet_address, :string
      add :agent_chain_id, :integer
      add :agent_registry_address, :string
      add :agent_token_id, :string
      add :agent_id, :string
      add :agent_label, :string
      add :signature_type, :string
      add :signature, :text
      add :signed_message, :text
      add :signed_at, :utc_datetime_usec
      add :signed_evidence, :map, null: false, default: %{}
      add :completion_ip, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:autolaunch_agent_pairing_sessions, [:session_id])
    create unique_index(:autolaunch_agent_pairing_sessions, [:pairing_code_hash])
    create unique_index(:autolaunch_agent_pairing_sessions, [:challenge_nonce])
    create index(:autolaunch_agent_pairing_sessions, [:human_user_id, :status])
    create index(:autolaunch_agent_pairing_sessions, [:privy_user_id])
    create index(:autolaunch_agent_pairing_sessions, [:expires_at])
    create index(:autolaunch_agent_pairing_sessions, [:agent_wallet_address])
    create index(:autolaunch_agent_pairing_sessions, [:agent_id])

    create unique_index(
             :autolaunch_agent_pairing_sessions,
             [:agent_chain_id, :agent_registry_address, :agent_token_id],
             name: :autolaunch_agent_pairings_completed_agent_unique,
             where:
               "status = 'completed' AND agent_chain_id IS NOT NULL AND agent_registry_address IS NOT NULL AND agent_token_id IS NOT NULL"
           )
  end
end
