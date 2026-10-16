defmodule Mix.Tasks.Autolaunch.Shared.Migrate do
  @shortdoc "Migrates the shared Regent schemas into a local Autolaunch database"
  @moduledoc """
  Autolaunch reads tables it does not own: the shared account table, Regents'
  identity tables, the agents people pair, their Credits and their Points. Regents and the
  platform own them in production, and a release only checks the shared
  migrations are there (`Autolaunch.Release`); locally each site creates them, as
  ash-template does. `mix db.setup`, and so `mix test`, runs this task.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    unless Mix.env() in [:dev, :test], do: Mix.raise("local database setup is dev and test only")

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Autolaunch.Repo, fn repo ->
        create_shared_tables!(repo)
        RegentAgents.Migrator.up(repo)
        RegentCredits.Migrator.up(repo)
        RegentPoints.Migrator.up(repo)
        RegentIdentity.Migrator.up(repo)
      end)
  end

  # The shared account table in the shape production has it, from
  # `priv/repo/shared_tables.sql`. Every statement in the file is idempotent, so an
  # already prepared database is left as it is. The file ships inside this
  # application's priv directory and holds only DDL written in this repository,
  # so neither the path nor the statements come from input.
  # sobelow_skip ["SQL.Query", "Traversal.FileModule"]
  defp create_shared_tables!(repo) do
    :autolaunch
    |> Application.app_dir("priv/repo/shared_tables.sql")
    |> File.read!()
    |> String.split(";\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&Ecto.Adapters.SQL.query!(repo, &1, []))
  end
end
