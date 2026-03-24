defmodule Autolaunch.Repo.Migrations.HardCutoverMainnetRevenueShare do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE autolaunch_jobs
    ADD COLUMN IF NOT EXISTS launch_fee_registry_address varchar,
    ADD COLUMN IF NOT EXISTS launch_fee_vault_address varchar
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
    ADD COLUMN IF NOT EXISTS subject_registry_address varchar,
    ADD COLUMN IF NOT EXISTS subject_id varchar,
    ADD COLUMN IF NOT EXISTS revenue_share_splitter_address varchar
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'autolaunch_jobs'
          AND column_name = 'fee_vault_address'
      ) THEN
        UPDATE autolaunch_jobs
        SET launch_fee_vault_address = COALESCE(launch_fee_vault_address, fee_vault_address)
        WHERE fee_vault_address IS NOT NULL;
      END IF;
    END
    $$;
    """)

    execute("""
    ALTER TABLE autolaunch_agentbook_sessions
    ADD COLUMN IF NOT EXISTS launch_job_id varchar,
    ADD COLUMN IF NOT EXISTS human_id varchar
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS autolaunch_agentbook_sessions_launch_job_id_index ON autolaunch_agentbook_sessions (launch_job_id)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS autolaunch_agentbook_sessions_human_id_index ON autolaunch_agentbook_sessions (human_id)"
    )

    execute("""
    UPDATE autolaunch_auctions
    SET target_currency = 'Not published'
    WHERE target_currency IN ('150 ETH', '150 USDC', '150,000 USDC')
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
