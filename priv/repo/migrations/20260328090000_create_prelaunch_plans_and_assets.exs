defmodule Autolaunch.Repo.Migrations.CreatePrelaunchPlansAndAssets do
  use Ecto.Migration

  def change do
    create table(:autolaunch_prelaunch_assets) do
      add :asset_id, :string, null: false
      add :privy_user_id, :string, null: false
      add :file_name, :string, null: false
      add :media_type, :string, null: false
      add :storage_path, :text
      add :source_url, :text
      add :public_url, :text, null: false
      add :byte_size, :bigint
      add :sha256, :string

      timestamps()
    end

    create unique_index(:autolaunch_prelaunch_assets, [:asset_id])
    create index(:autolaunch_prelaunch_assets, [:privy_user_id])

    create table(:autolaunch_prelaunch_plans) do
      add :plan_id, :string, null: false
      add :privy_user_id, :string, null: false
      add :state, :string, null: false, default: "draft"
      add :agent_id, :string, null: false
      add :agent_name, :string
      add :chain_id, :bigint, null: false, default: 84_532
      add :token_name, :string, null: false
      add :token_symbol, :string, null: false
      add :treasury_safe_address, :string, null: false
      add :auction_proceeds_recipient, :string, null: false
      add :ethereum_revenue_treasury, :string, null: false
      add :backup_safe_address, :string
      add :fallback_operator_wallet, :string
      add :launch_notes, :text
      add :identity_snapshot, :map, null: false, default: %{}
      add :metadata_draft, :map, null: false, default: %{}
      add :validation_summary, :map, null: false, default: %{}
      add :published_metadata_url, :text
      add :launch_job_id, :string

      timestamps()
    end

    create unique_index(:autolaunch_prelaunch_plans, [:plan_id])
    create index(:autolaunch_prelaunch_plans, [:privy_user_id])
    create index(:autolaunch_prelaunch_plans, [:agent_id])
    create index(:autolaunch_prelaunch_plans, [:launch_job_id])
  end
end
