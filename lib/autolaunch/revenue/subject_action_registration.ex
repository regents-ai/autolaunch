defmodule Autolaunch.Revenue.SubjectActionRegistration do
  @moduledoc false
  use Autolaunch.Schema

  schema "autolaunch_subject_action_registrations" do
    field :subject_id, :string
    field :action, :string
    field :owner_address, :string
    field :chain_id, :integer
    field :tx_hash, :string
    field :ingress_address, :string
    field :amount, :string
    field :status, :string, default: "pending"
    field :block_number, :integer
    field :error_code, :string
    field :error_message, :string

    timestamps()
  end

  def create_changeset(registration, attrs) do
    registration
    |> cast(attrs, [
      :subject_id,
      :action,
      :owner_address,
      :chain_id,
      :tx_hash,
      :ingress_address,
      :amount,
      :status,
      :block_number,
      :error_code,
      :error_message
    ])
    |> validate_required([:subject_id, :action, :owner_address, :chain_id, :tx_hash, :status])
    |> validate_inclusion(:action, [
      "stake",
      "unstake",
      "claim_usdc",
      "claim_emissions",
      "claim_and_stake_emissions",
      "sweep_ingress"
    ])
    |> validate_inclusion(:status, ["pending", "confirmed", "rejected"])
    |> unique_constraint(:tx_hash,
      name: :autolaunch_subject_action_registrations_tx_hash_unique
    )
  end

  def update_status_changeset(registration, attrs) do
    registration
    |> cast(attrs, [:status, :block_number, :error_code, :error_message])
    |> validate_inclusion(:status, ["pending", "confirmed", "rejected"])
  end
end
