defmodule Autolaunch.Repo.Migrations.SetPrelaunchPlanDefaultsToBaseMainnet do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE autolaunch_prelaunch_plans
      ALTER COLUMN chain_id SET DEFAULT 8453
    """)
  end

  def down do
    raise "hard cutover only"
  end
end
