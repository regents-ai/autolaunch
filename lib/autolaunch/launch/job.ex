defmodule Autolaunch.Launch.Job do
  @moduledoc false
  use Autolaunch.Schema

  @primary_key {:job_id, :string, autogenerate: false}
  @sepolia_network "ethereum-sepolia"
  @sepolia_chain_id 11_155_111

  schema "autolaunch_jobs" do
    field :privy_user_id, :string
    field :owner_address, :string
    field :agent_id, :string
    field :agent_name, :string
    field :ens_name, :string
    field :token_name, :string
    field :token_symbol, :string
    field :minimum_raise_usdc, :string
    field :minimum_raise_usdc_raw, :string
    field :recovery_safe_address, :string
    field :auction_proceeds_recipient, :string
    field :ethereum_revenue_treasury, :string
    field :network, :string, default: @sepolia_network
    field :chain_id, :integer, default: @sepolia_chain_id
    field :broadcast, :boolean, default: true
    field :status, :string, default: "queued"
    field :step, :string, default: "queued"
    field :error_message, :string
    field :launch_notes, :string
    field :total_supply, :string
    field :lifecycle_run_id, :string
    field :message, :string
    field :siwa_nonce, :string
    field :siwa_signature, :string
    field :issued_at, :utc_datetime_usec
    field :request_ip, :string
    field :script_target, :string
    field :deploy_workdir, :string
    field :deploy_binary, :string
    field :rpc_host, :string
    field :auction_address, :string
    field :token_address, :string
    field :strategy_address, :string
    field :vesting_wallet_address, :string
    field :hook_address, :string
    field :launch_fee_registry_address, :string
    field :launch_fee_vault_address, :string
    field :subject_registry_address, :string
    field :subject_id, :string
    field :revenue_share_splitter_address, :string
    field :default_ingress_address, :string
    field :pool_id, :string
    field :tx_hash, :string
    field :uniswap_url, :string
    field :stdout_tail, :string
    field :stderr_tail, :string
    field :world_network, :string, default: "world"
    field :world_registered, :boolean, default: false
    field :world_human_id, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps()
  end

  def create_changeset(job, attrs) do
    job
    |> cast(attrs, [
      :job_id,
      :privy_user_id,
      :owner_address,
      :agent_id,
      :agent_name,
      :ens_name,
      :token_name,
      :token_symbol,
      :minimum_raise_usdc,
      :minimum_raise_usdc_raw,
      :recovery_safe_address,
      :auction_proceeds_recipient,
      :ethereum_revenue_treasury,
      :network,
      :chain_id,
      :broadcast,
      :status,
      :step,
      :launch_notes,
      :total_supply,
      :lifecycle_run_id,
      :message,
      :siwa_nonce,
      :siwa_signature,
      :issued_at,
      :request_ip,
      :script_target,
      :deploy_workdir,
      :deploy_binary,
      :rpc_host
    ])
    |> validate_required([
      :job_id,
      :owner_address,
      :agent_id,
      :token_name,
      :token_symbol,
      :recovery_safe_address,
      :auction_proceeds_recipient,
      :ethereum_revenue_treasury,
      :network,
      :chain_id,
      :status,
      :step,
      :total_supply,
      :message,
      :siwa_nonce,
      :siwa_signature,
      :issued_at
    ])
    |> validate_inclusion(:network, [@sepolia_network])
    |> validate_inclusion(:chain_id, [@sepolia_chain_id])
  end

  def update_changeset(job, attrs) do
    cast(job, attrs, [
      :status,
      :step,
      :error_message,
      :auction_address,
      :token_address,
      :strategy_address,
      :vesting_wallet_address,
      :hook_address,
      :launch_fee_registry_address,
      :launch_fee_vault_address,
      :subject_registry_address,
      :subject_id,
      :revenue_share_splitter_address,
      :default_ingress_address,
      :pool_id,
      :tx_hash,
      :uniswap_url,
      :stdout_tail,
      :stderr_tail,
      :world_network,
      :world_registered,
      :world_human_id,
      :started_at,
      :finished_at
    ])
  end
end
