defmodule Autolaunch.Repo.Migrations.HardCutoverMainnetRevenueShare do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE autolaunch_jobs
    ADD COLUMN IF NOT EXISTS launch_fee_vault_address varchar
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
    DROP COLUMN IF EXISTS emission_recipient,
    DROP COLUMN IF EXISTS default_ingress_address,
    DROP COLUMN IF EXISTS revenue_ingress_router_address,
    DROP COLUMN IF EXISTS epoch_seconds,
    DROP COLUMN IF EXISTS treasury_address,
    DROP COLUMN IF EXISTS vesting_beneficiary,
    DROP COLUMN IF EXISTS base_revenue_treasury,
    DROP COLUMN IF EXISTS tempo_revenue_treasury,
    DROP COLUMN IF EXISTS base_emission_recipient,
    DROP COLUMN IF EXISTS registry_address,
    DROP COLUMN IF EXISTS rights_hub_address,
    DROP COLUMN IF EXISTS ethereum_vault_address,
    DROP COLUMN IF EXISTS base_vault_address,
    DROP COLUMN IF EXISTS tempo_vault_address,
    DROP COLUMN IF EXISTS regent_emissions_distributor_address,
    DROP COLUMN IF EXISTS ethereum_splitter_address,
    DROP COLUMN IF EXISTS official_pool_id,
    DROP COLUMN IF EXISTS fee_vault_address
    """)

    execute("DROP TABLE IF EXISTS autolaunch_publisher_deposits CASCADE")
    execute("DROP TABLE IF EXISTS autolaunch_publisher_stakers CASCADE")
    execute("DROP TABLE IF EXISTS autolaunch_publisher_artifacts CASCADE")
    execute("DROP TABLE IF EXISTS autolaunch_subject_revenue_snapshots CASCADE")
    execute("DROP TABLE IF EXISTS autolaunch_epoch_roots CASCADE")
    execute("DROP TABLE IF EXISTS autolaunch_chain_revenue_snapshots CASCADE")
    execute("DROP TABLE IF EXISTS autolaunch_regent_epochs CASCADE")
  end

  def down do
    raise "hard cutover only"
  end
end
