defmodule Autolaunch.AgentPairings.Session do
  @moduledoc false
  use Autolaunch.Schema

  alias Autolaunch.Accounts.HumanUser

  @statuses ~w(pending completed expired)
  @signature_types ~w(evm_personal_sign)

  schema "autolaunch_agent_pairing_sessions" do
    field :session_id, :string
    field :privy_user_id, :string
    field :status, :string, default: "pending"
    field :pairing_code_hash, :string
    field :challenge_nonce, :string
    field :challenge_message, :string
    field :expires_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :agent_wallet_address, :string
    field :agent_chain_id, :integer
    field :agent_registry_address, :string
    field :agent_token_id, :string
    field :agent_id, :string
    field :agent_label, :string
    field :signature_type, :string
    field :signature, :string
    field :signed_message, :string
    field :signed_at, :utc_datetime_usec
    field :signed_evidence, :map, default: %{}
    field :completion_ip, :string

    belongs_to :human_user, HumanUser

    timestamps()
  end

  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :session_id,
      :human_user_id,
      :privy_user_id,
      :status,
      :pairing_code_hash,
      :challenge_nonce,
      :challenge_message,
      :expires_at
    ])
    |> validate_required([
      :session_id,
      :human_user_id,
      :privy_user_id,
      :status,
      :pairing_code_hash,
      :challenge_nonce,
      :challenge_message,
      :expires_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:session_id)
    |> unique_constraint(:pairing_code_hash)
    |> unique_constraint(:challenge_nonce)
    |> foreign_key_constraint(:human_user_id)
  end

  def complete_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :status,
      :completed_at,
      :agent_wallet_address,
      :agent_chain_id,
      :agent_registry_address,
      :agent_token_id,
      :agent_id,
      :agent_label,
      :signature_type,
      :signature,
      :signed_message,
      :signed_at,
      :signed_evidence,
      :completion_ip
    ])
    |> validate_required([
      :status,
      :completed_at,
      :agent_wallet_address,
      :agent_chain_id,
      :agent_registry_address,
      :agent_token_id,
      :agent_id,
      :signature_type,
      :signature,
      :signed_message,
      :signed_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:signature_type, @signature_types)
    |> validate_inclusion(:agent_chain_id, [84_532, 8_453])
    |> validate_length(:agent_token_id, min: 1, max: 255)
    |> validate_length(:agent_id, min: 1, max: 255)
    |> validate_length(:agent_label, max: 80)
    |> unique_constraint(:agent_token_id,
      name: :autolaunch_agent_pairings_completed_agent_unique
    )
  end

  def expire_changeset(session, attrs) do
    session
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end
end
