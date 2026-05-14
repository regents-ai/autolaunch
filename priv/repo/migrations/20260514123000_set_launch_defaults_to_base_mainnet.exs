defmodule Autolaunch.Repo.Migrations.SetLaunchDefaultsToBaseMainnet do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE autolaunch_jobs
      ALTER COLUMN network SET DEFAULT 'base-mainnet',
      ALTER COLUMN chain_id SET DEFAULT 8453
    """)

    execute("""
    ALTER TABLE autolaunch_auctions
      ALTER COLUMN network SET DEFAULT 'base-mainnet',
      ALTER COLUMN chain_id SET DEFAULT 8453
    """)

    execute("""
    ALTER TABLE autolaunch_bids
      ALTER COLUMN network SET DEFAULT 'base-mainnet',
      ALTER COLUMN chain_id SET DEFAULT 8453
    """)
  end

  def down do
    execute("""
    ALTER TABLE autolaunch_jobs
      ALTER COLUMN network SET DEFAULT 'base-sepolia',
      ALTER COLUMN chain_id SET DEFAULT 84532
    """)

    execute("""
    ALTER TABLE autolaunch_auctions
      ALTER COLUMN network SET DEFAULT 'base-sepolia',
      ALTER COLUMN chain_id SET DEFAULT 84532
    """)

    execute("""
    ALTER TABLE autolaunch_bids
      ALTER COLUMN network SET DEFAULT 'base-sepolia',
      ALTER COLUMN chain_id SET DEFAULT 84532
    """)
  end
end
