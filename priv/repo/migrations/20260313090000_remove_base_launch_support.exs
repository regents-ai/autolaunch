defmodule Autolaunch.Repo.Migrations.RemoveBaseLaunchSupport do
  use Ecto.Migration

  def up do
    execute("DELETE FROM autolaunch_bids WHERE chain_id NOT IN (8453, 84532)")

    execute("DELETE FROM autolaunch_auctions WHERE chain_id NOT IN (8453, 84532)")

    execute("DELETE FROM autolaunch_jobs WHERE chain_id NOT IN (8453, 84532)")

    alter table(:autolaunch_jobs) do
      modify :network, :string, null: false, default: "base-mainnet"
      modify :chain_id, :integer, null: false, default: 8453
    end

    alter table(:autolaunch_auctions) do
      modify :network, :string, null: false, default: "base-mainnet"
      modify :chain_id, :integer, null: false, default: 8453
    end

    alter table(:autolaunch_bids) do
      modify :chain_id, :integer, null: false, default: 8453
    end

    create constraint(:autolaunch_jobs, :autolaunch_jobs_chain_id_base_only,
             check: "chain_id IN (8453, 84532)"
           )

    create constraint(:autolaunch_jobs, :autolaunch_jobs_network_base_only,
             check: "network IN ('base-mainnet', 'base-sepolia')"
           )

    create constraint(:autolaunch_auctions, :autolaunch_auctions_chain_id_base_only,
             check: "chain_id IN (8453, 84532)"
           )

    create constraint(:autolaunch_auctions, :autolaunch_auctions_network_base_only,
             check: "network IN ('base-mainnet', 'base-sepolia')"
           )

    create constraint(:autolaunch_bids, :autolaunch_bids_chain_id_base_only,
             check: "chain_id IN (8453, 84532)"
           )

    create constraint(:autolaunch_bids, :autolaunch_bids_network_base_only,
             check: "network IN ('base-mainnet', 'base-sepolia')"
           )
  end

  def down do
    drop constraint(:autolaunch_bids, :autolaunch_bids_network_base_only)
    drop constraint(:autolaunch_bids, :autolaunch_bids_chain_id_base_only)
    drop constraint(:autolaunch_auctions, :autolaunch_auctions_network_base_only)
    drop constraint(:autolaunch_auctions, :autolaunch_auctions_chain_id_base_only)
    drop constraint(:autolaunch_jobs, :autolaunch_jobs_network_base_only)
    drop constraint(:autolaunch_jobs, :autolaunch_jobs_chain_id_base_only)

    alter table(:autolaunch_jobs) do
      modify :network, :string, null: false, default: "base-mainnet"
      modify :chain_id, :integer, null: false, default: 8453
    end

    alter table(:autolaunch_auctions) do
      modify :network, :string, null: false, default: "base-mainnet"
      modify :chain_id, :integer, null: false, default: 8453
    end

    alter table(:autolaunch_bids) do
      modify :chain_id, :integer, null: false, default: 8453
    end
  end
end
