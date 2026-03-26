defmodule Autolaunch.Repo.Migrations.LaunchV2CutoverFields do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE autolaunch_jobs
    ADD COLUMN IF NOT EXISTS strategy_address varchar,
    ADD COLUMN IF NOT EXISTS vesting_wallet_address varchar
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
    DROP COLUMN IF EXISTS revenue_ingress_router_address
    """)
  end

  def down do
    raise "hard cutover only"
  end
end
