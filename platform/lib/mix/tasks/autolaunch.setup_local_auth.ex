defmodule Mix.Tasks.Autolaunch.SetupLocalAuth do
  use Mix.Task

  @shortdoc "Prepares the guarded local Autolaunch database"

  # Only the database connection runs, so a database without the job tables yet
  # can still be brought up to date; `mix test` runs this first.
  @impl true
  def run(_args) do
    unless Mix.env() in [:dev, :test], do: Mix.raise("local database setup is dev and test only")
    Mix.Task.run("app.config")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Autolaunch.Repo, fn _repo ->
        Autolaunch.LocalDatabaseFixture.ensure_human_accounts!()
      end)

    Mix.shell().info("Local Autolaunch database is ready.")
  end
end
