defmodule Mix.Tasks.Autolaunch.Identity.Migrate do
  @shortdoc "Migrates the shared Regent identity schema into the Autolaunch database"
  @moduledoc """
  The profile page reads the shared `regent_identity` schema, which the product's
  own migrations never create. Releases run `RegentIdentity.Migrator` from
  `Autolaunch.Release`; this task does the same for a local or test database.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    {:ok, _versions, _apps} =
      Ecto.Migrator.with_repo(Autolaunch.Repo, &RegentIdentity.Migrator.up/1)
  end
end
