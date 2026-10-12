defmodule Autolaunch.Repo.Migrations.AddErrorTracker do
  use Ecto.Migration

  # ErrorTracker's own tables, in the schema the site's own tables use.
  def up,
    do: ErrorTracker.Migration.up(prefix: Autolaunch.Repo.default_prefix(), create_schema: false)

  def down, do: ErrorTracker.Migration.down(prefix: Autolaunch.Repo.default_prefix(), version: 1)
end
