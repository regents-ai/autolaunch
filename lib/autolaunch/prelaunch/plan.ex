defmodule Autolaunch.Prelaunch.Plan do
  @moduledoc false
  use Autolaunch.Schema

  @states ~w(draft validated launchable launched archived)
  @primary_key {:id, :id, autogenerate: true}

  schema "autolaunch_prelaunch_plans" do
    field :plan_id, :string
    field :privy_user_id, :string
    field :state, :string, default: "draft"
    field :agent_id, :string
    field :agent_name, :string
    field :chain_id, :integer, default: 11_155_111
    field :token_name, :string
    field :token_symbol, :string
    field :treasury_safe_address, :string
    field :auction_proceeds_recipient, :string
    field :ethereum_revenue_treasury, :string
    field :backup_safe_address, :string
    field :fallback_operator_wallet, :string
    field :launch_notes, :string
    field :identity_snapshot, :map, default: %{}
    field :metadata_draft, :map, default: %{}
    field :validation_summary, :map, default: %{}
    field :published_metadata_url, :string
    field :launch_job_id, :string

    timestamps()
  end

  def create_changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :plan_id,
      :privy_user_id,
      :state,
      :agent_id,
      :agent_name,
      :chain_id,
      :token_name,
      :token_symbol,
      :treasury_safe_address,
      :auction_proceeds_recipient,
      :ethereum_revenue_treasury,
      :backup_safe_address,
      :fallback_operator_wallet,
      :launch_notes,
      :identity_snapshot,
      :metadata_draft,
      :validation_summary,
      :published_metadata_url,
      :launch_job_id
    ])
    |> validate_required([
      :plan_id,
      :privy_user_id,
      :state,
      :agent_id,
      :chain_id,
      :token_name,
      :token_symbol,
      :treasury_safe_address,
      :auction_proceeds_recipient,
      :ethereum_revenue_treasury
    ])
    |> validate_inclusion(:state, @states)
    |> validate_length(:token_name, min: 1, max: 80)
    |> validate_length(:token_symbol, min: 1, max: 16)
    |> validate_length(:launch_notes, max: 1_000)
    |> unique_constraint(:plan_id)
  end

  def update_changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :state,
      :agent_name,
      :token_name,
      :token_symbol,
      :treasury_safe_address,
      :auction_proceeds_recipient,
      :ethereum_revenue_treasury,
      :backup_safe_address,
      :fallback_operator_wallet,
      :launch_notes,
      :identity_snapshot,
      :metadata_draft,
      :validation_summary,
      :published_metadata_url,
      :launch_job_id
    ])
    |> validate_inclusion(:state, @states)
    |> validate_length(:token_name, min: 1, max: 80)
    |> validate_length(:token_symbol, min: 1, max: 16)
    |> validate_length(:launch_notes, max: 1_000)
  end
end
