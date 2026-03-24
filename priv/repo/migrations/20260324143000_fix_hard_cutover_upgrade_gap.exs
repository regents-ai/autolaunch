defmodule Autolaunch.Repo.Migrations.FixHardCutoverUpgradeGap do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE autolaunch_jobs
    ADD COLUMN IF NOT EXISTS launch_fee_registry_address varchar,
    ADD COLUMN IF NOT EXISTS launch_fee_vault_address varchar,
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
  end

  def down do
    raise "hard cutover only"
  end
end
