defmodule Autolaunch.Repo.Migrations.HardCutoverSepoliaLaunchDefaults do
  use Ecto.Migration

  @sepolia_network "ethereum-sepolia"
  @sepolia_chain_id 11_155_111

  def up do
    execute("""
    DELETE FROM autolaunch_bids
    WHERE network IS DISTINCT FROM '#{@sepolia_network}'
       OR chain_id IS DISTINCT FROM #{@sepolia_chain_id}
    """)

    execute("""
    DELETE FROM autolaunch_auctions
    WHERE network IS DISTINCT FROM '#{@sepolia_network}'
       OR chain_id IS DISTINCT FROM #{@sepolia_chain_id}
    """)

    execute("""
    DELETE FROM autolaunch_jobs
    WHERE network IS DISTINCT FROM '#{@sepolia_network}'
       OR chain_id IS DISTINCT FROM #{@sepolia_chain_id}
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
      ALTER COLUMN network SET DEFAULT '#{@sepolia_network}',
      ALTER COLUMN chain_id SET DEFAULT #{@sepolia_chain_id}
    """)

    execute("""
    ALTER TABLE autolaunch_auctions
      ALTER COLUMN network SET DEFAULT '#{@sepolia_network}',
      ALTER COLUMN chain_id SET DEFAULT #{@sepolia_chain_id}
    """)

    execute("""
    ALTER TABLE autolaunch_bids
      ALTER COLUMN network SET DEFAULT '#{@sepolia_network}',
      ALTER COLUMN chain_id SET DEFAULT #{@sepolia_chain_id}
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
      DROP CONSTRAINT IF EXISTS autolaunch_jobs_chain_id_ethereum_only,
      DROP CONSTRAINT IF EXISTS autolaunch_jobs_network_ethereum_only
    """)

    execute("""
    ALTER TABLE autolaunch_auctions
      DROP CONSTRAINT IF EXISTS autolaunch_auctions_chain_id_ethereum_only,
      DROP CONSTRAINT IF EXISTS autolaunch_auctions_network_ethereum_only
    """)

    execute("""
    ALTER TABLE autolaunch_bids
      DROP CONSTRAINT IF EXISTS autolaunch_bids_chain_id_ethereum_only,
      DROP CONSTRAINT IF EXISTS autolaunch_bids_network_ethereum_only
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
      ADD CONSTRAINT autolaunch_jobs_chain_id_sepolia_only CHECK (chain_id = #{@sepolia_chain_id}),
      ADD CONSTRAINT autolaunch_jobs_network_sepolia_only CHECK (network = '#{@sepolia_network}')
    """)

    execute("""
    ALTER TABLE autolaunch_auctions
      ADD CONSTRAINT autolaunch_auctions_chain_id_sepolia_only CHECK (chain_id = #{@sepolia_chain_id}),
      ADD CONSTRAINT autolaunch_auctions_network_sepolia_only CHECK (network = '#{@sepolia_network}')
    """)

    execute("""
    ALTER TABLE autolaunch_bids
      ADD CONSTRAINT autolaunch_bids_chain_id_sepolia_only CHECK (chain_id = #{@sepolia_chain_id}),
      ADD CONSTRAINT autolaunch_bids_network_sepolia_only CHECK (network = '#{@sepolia_network}')
    """)
  end

  def down do
    execute("""
    ALTER TABLE autolaunch_bids
      DROP CONSTRAINT IF EXISTS autolaunch_bids_network_sepolia_only,
      DROP CONSTRAINT IF EXISTS autolaunch_bids_chain_id_sepolia_only
    """)

    execute("""
    ALTER TABLE autolaunch_auctions
      DROP CONSTRAINT IF EXISTS autolaunch_auctions_network_sepolia_only,
      DROP CONSTRAINT IF EXISTS autolaunch_auctions_chain_id_sepolia_only
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
      DROP CONSTRAINT IF EXISTS autolaunch_jobs_network_sepolia_only,
      DROP CONSTRAINT IF EXISTS autolaunch_jobs_chain_id_sepolia_only
    """)

    execute("""
    ALTER TABLE autolaunch_bids
      ALTER COLUMN network SET DEFAULT 'ethereum-mainnet',
      ALTER COLUMN chain_id SET DEFAULT 1
    """)

    execute("""
    ALTER TABLE autolaunch_auctions
      ALTER COLUMN network SET DEFAULT 'ethereum-mainnet',
      ALTER COLUMN chain_id SET DEFAULT 1
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
      ALTER COLUMN network SET DEFAULT 'ethereum-mainnet',
      ALTER COLUMN chain_id SET DEFAULT 1
    """)

    execute("""
    ALTER TABLE autolaunch_bids
      ADD CONSTRAINT autolaunch_bids_chain_id_ethereum_only CHECK (chain_id IN (1, 11155111)),
      ADD CONSTRAINT autolaunch_bids_network_ethereum_only CHECK (network IN ('ethereum-mainnet', 'ethereum-sepolia'))
    """)

    execute("""
    ALTER TABLE autolaunch_auctions
      ADD CONSTRAINT autolaunch_auctions_chain_id_ethereum_only CHECK (chain_id IN (1, 11155111)),
      ADD CONSTRAINT autolaunch_auctions_network_ethereum_only CHECK (network IN ('ethereum-mainnet', 'ethereum-sepolia'))
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
      ADD CONSTRAINT autolaunch_jobs_chain_id_ethereum_only CHECK (chain_id IN (1, 11155111)),
      ADD CONSTRAINT autolaunch_jobs_network_ethereum_only CHECK (network IN ('ethereum-mainnet', 'ethereum-sepolia'))
    """)
  end
end
