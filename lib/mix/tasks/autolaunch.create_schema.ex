defmodule Mix.Tasks.Autolaunch.CreateSchema do
  @moduledoc false

  use Mix.Task

  @shortdoc "Creates the Autolaunch database schema"
  @schema "autolaunch"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    for repo <- Application.fetch_env!(:autolaunch, :ecto_repos) do
      Ecto.Adapters.SQL.query!(repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{@schema}"), [])
    end
  end
end
