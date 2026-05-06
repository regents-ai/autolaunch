defmodule Autolaunch.Release do
  @moduledoc """
  Release tasks for running Autolaunch in production without Mix.
  """

  @app :autolaunch
  @schema "autolaunch"
  @migration_source "schema_migrations_autolaunch"
  @schema_search_path ~s(SET search_path TO "#{@schema}",public)

  def migrate do
    load_app()
    configure_repo_for_migrations!()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          create_schema!(repo)
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  def rollback(repo, version) do
    load_app()
    configure_repo_for_migrations!()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        create_schema!(repo)
        Ecto.Migrator.run(repo, :down, to: version)
      end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  defp configure_repo_for_migrations! do
    direct_url = System.fetch_env!("DATABASE_DIRECT_URL")

    Enum.each(repos(), fn repo ->
      config =
        repo.config()
        |> Keyword.put(:url, direct_url)
        |> Keyword.put(:ssl, database_ssl?())
        |> Keyword.put(:prepare, :unnamed)
        |> Keyword.put(:after_connect, {Postgrex, :query!, [@schema_search_path, []]})
        |> Keyword.put(:pool_size, String.to_integer(System.get_env("ECTO_POOL_SIZE") || "5"))
        |> Keyword.put(:migration_default_prefix, @schema)
        |> Keyword.put(:migration_source, @migration_source)

      Application.put_env(@app, repo, config)
    end)
  end

  defp create_schema!(repo) do
    Ecto.Adapters.SQL.query!(repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{@schema}"), [])
  end

  defp database_ssl? do
    System.get_env("DATABASE_SSL", "true") in ["1", "true", "TRUE"]
  end
end
