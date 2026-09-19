defmodule Mix.Tasks.Autolaunch.Schema.Create do
  @shortdoc "Creates the autolaunch_app schema in the configured database"
  @moduledoc """
  Creates the product schema on a database that was just created, so the
  migrations that follow have somewhere to run. The `setup` and `test` aliases
  run it between creating the database and migrating.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _, _} = Ecto.Migrator.with_repo(Autolaunch.Repo, &Autolaunch.Release.ensure_schema!/1)
    :ok
  end
end
