defmodule Autolaunch.Repo.Migrations.AddMinimumRaiseToLaunchRecords do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE autolaunch_prelaunch_plans
    ADD COLUMN IF NOT EXISTS minimum_raise_usdc varchar,
    ADD COLUMN IF NOT EXISTS minimum_raise_usdc_raw varchar
    """)

    execute("""
    ALTER TABLE autolaunch_jobs
    ADD COLUMN IF NOT EXISTS minimum_raise_usdc varchar,
    ADD COLUMN IF NOT EXISTS minimum_raise_usdc_raw varchar
    """)

    execute("""
    ALTER TABLE autolaunch_auctions
    ADD COLUMN IF NOT EXISTS minimum_raise_usdc varchar,
    ADD COLUMN IF NOT EXISTS minimum_raise_usdc_raw varchar
    """)
  end

  def down do
    raise "hard cutover only"
  end
end
