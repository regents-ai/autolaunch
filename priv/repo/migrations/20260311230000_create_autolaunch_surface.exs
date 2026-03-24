defmodule Autolaunch.Repo.Migrations.CreateAutolaunchSurface do
  use Ecto.Migration

  def change do
    create table(:autolaunch_human_users) do
      add :privy_user_id, :string, null: false
      add :wallet_address, :string
      add :display_name, :string
      add :role, :string, null: false, default: "user"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:autolaunch_human_users, [:privy_user_id])

    create table(:autolaunch_jobs, primary_key: false) do
      add :job_id, :string, primary_key: true
      add :privy_user_id, :string
      add :owner_address, :string, null: false
      add :agent_id, :string, null: false
      add :agent_name, :string
      add :ens_name, :string
      add :token_name, :string
      add :token_symbol, :string
      add :recovery_safe_address, :string, null: false
      add :auction_proceeds_recipient, :string, null: false
      add :ethereum_revenue_treasury, :string, null: false
      add :network, :string, null: false, default: "ethereum-mainnet"
      add :chain_id, :integer, null: false, default: 1
      add :broadcast, :boolean, null: false, default: true
      add :status, :string, null: false, default: "queued"
      add :step, :string, null: false, default: "queued"
      add :error_message, :text
      add :launch_notes, :text
      add :total_supply, :text, null: false
      add :lifecycle_run_id, :string
      add :message, :text, null: false
      add :siwa_nonce, :string, null: false
      add :siwa_signature, :text, null: false
      add :issued_at, :utc_datetime_usec, null: false
      add :request_ip, :string
      add :script_target, :text
      add :deploy_workdir, :text
      add :deploy_binary, :string
      add :rpc_host, :string
      add :auction_address, :string
      add :token_address, :string
      add :hook_address, :string
      add :launch_fee_registry_address, :string
      add :launch_fee_vault_address, :string
      add :subject_registry_address, :string
      add :subject_id, :string
      add :revenue_share_splitter_address, :string
      add :tx_hash, :string
      add :uniswap_url, :text
      add :stdout_tail, :text
      add :stderr_tail, :text
      add :world_network, :string, null: false, default: "world"
      add :world_registered, :boolean, null: false, default: false
      add :world_human_id, :string
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:autolaunch_jobs, [:owner_address])
    create index(:autolaunch_jobs, [:status])
    create index(:autolaunch_jobs, [:agent_id])
    create index(:autolaunch_jobs, [:world_human_id])
    create unique_index(:autolaunch_jobs, [:siwa_nonce], name: :autolaunch_jobs_nonce_unique)

    create table(:autolaunch_auctions) do
      add :source_job_id, :string
      add :agent_id, :string, null: false
      add :agent_name, :string, null: false
      add :owner_address, :string, null: false
      add :auction_address, :string, null: false
      add :token_address, :string
      add :network, :string, null: false, default: "ethereum-mainnet"
      add :chain_id, :integer, null: false, default: 1
      add :status, :string, null: false, default: "active"
      add :started_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec
      add :claim_at, :utc_datetime_usec
      add :bidders, :integer, null: false, default: 0
      add :raised_currency, :string, null: false, default: "0 USDC"
      add :target_currency, :string, null: false, default: "Not published"
      add :progress_percent, :integer, null: false, default: 0
      add :metrics_updated_at, :utc_datetime_usec
      add :notes, :text
      add :uniswap_url, :text
      add :ens_name, :string
      add :world_network, :string, null: false, default: "world"
      add :world_registered, :boolean, null: false, default: false
      add :world_human_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:autolaunch_auctions, [:owner_address])
    create index(:autolaunch_auctions, [:status])
    create index(:autolaunch_auctions, [:ends_at])
    create index(:autolaunch_auctions, [:world_human_id])

    create unique_index(:autolaunch_auctions, [:network, :auction_address],
             name: :autolaunch_auctions_network_address_unique
           )

    create table(:autolaunch_bids, primary_key: false) do
      add :bid_id, :string, primary_key: true
      add :privy_user_id, :string
      add :owner_address, :string, null: false
      add :auction_id, :string, null: false
      add :auction_address, :string
      add :agent_id, :string, null: false
      add :agent_name, :string
      add :network, :string, null: false
      add :amount, :decimal, precision: 18, scale: 6, null: false
      add :max_price, :decimal, precision: 18, scale: 6, null: false
      add :current_clearing_price, :decimal, precision: 18, scale: 6, null: false
      add :current_status, :string, null: false, default: "active"
      add :estimated_tokens_if_end_now, :decimal, precision: 24, scale: 6
      add :estimated_tokens_if_no_other_bids_change, :decimal, precision: 24, scale: 6
      add :inactive_above_price, :decimal, precision: 18, scale: 6
      add :quote_snapshot, :map
      add :exited_at, :utc_datetime_usec
      add :claimed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:autolaunch_bids, [:owner_address])
    create index(:autolaunch_bids, [:auction_id])
    create index(:autolaunch_bids, [:current_status])
  end
end
