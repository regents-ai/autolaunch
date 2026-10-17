defmodule Autolaunch.Release do
  @moduledoc false

  @app :autolaunch
  @missing_migration_table_error "no schema_migrations table: the database has never been migrated"

  def migration_config! do
    Autolaunch.DatabaseConfig.release_config!()
    |> Keyword.merge(
      default_prefix: Autolaunch.Repo.default_prefix(),
      migration_default_prefix: Autolaunch.Repo.default_prefix()
    )
  end

  def migrate do
    load_app()
    Application.put_env(@app, Autolaunch.Repo, migration_config!())

    Ecto.Migrator.with_repo(Autolaunch.Repo, fn repo ->
      :ok = require_shared_migrations!(repo)
      RegentAgents.Migrator.require_pairing_history!(repo)
      RegentCredits.Migrator.require_pairing_grants!(repo)
      ensure_schema!(repo)
      Ecto.Migrator.run(repo, migrations_path(), :up, all: true, prefix: repo.default_prefix())
    end)
  end

  @doc """
  Undoes this site's own migrations from the newest back to and including
  `version`, the way `migrate/0` applies them. The database is shared by every Regent site,
  so going back to an earlier version is done this way, never by restoring it.
  """
  def rollback(version) when is_integer(version) do
    load_app()
    Application.put_env(@app, Autolaunch.Repo, migration_config!())

    Ecto.Migrator.with_repo(Autolaunch.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_path(), :down,
        to: version,
        prefix: repo.default_prefix()
      )
    end)
  end

  # The Agents, Credits and Points code this release carries reads tables and columns
  # from every migration its pinned library ships, so each must already be in
  # that schema's own ledger. Every missing version is named at once.
  defp require_shared_migrations!(repo) do
    case unapplied_shared_migrations(repo) do
      [] ->
        :ok

      unapplied ->
        raise "These separately approved shared migrations must be applied before deployment: " <>
                Enum.join(unapplied, ", ")
    end
  end

  defp unapplied_shared_migrations(repo) do
    for {app, schema} <- [
          regent_agents: "regent_agents",
          regent_credits: "regent_credits",
          regent_points: "regent_points"
        ],
        {:down, version, _name} <-
          Ecto.Migrator.migrations(repo, [Application.app_dir(app, "priv/repo/migrations")],
            prefix: schema,
            skip_table_creation: true,
            migration_lock: false
          ),
        do: "#{schema} #{version}"
  end

  @doc "Creates the product schema when the database does not have it yet."
  def ensure_schema!(repo) do
    repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{repo.default_prefix()}"), [])
    :ok
  end

  @doc """
  Lists what a deployed database and the release disagree about.

  Prints every migration the release carries that the database has not applied
  under `pending:`, every version the database has applied whose file the
  release does not carry under `applied-without-file:`, and the shared Agents,
  Credits and Points changes the release needs that their own ledgers do not hold under
  `shared-pending:` (each as schema and version; a deployment is refused while
  one is listed). Prints `none` when all three are empty. It applies nothing,
  creates nothing, and takes no migration lock.
  """
  def pending_migrations do
    load_app()
    Application.put_env(@app, Autolaunch.Repo, migration_config!())
    path = migrations_path()

    {:ok, {{pending, applied_without_file}, shared}, _started} =
      Ecto.Migrator.with_repo(Autolaunch.Repo, fn repo ->
        {collect_disagreements(repo, path), unapplied_shared_migrations(repo)}
      end)

    report(pending, applied_without_file, shared)
  end

  defp collect_disagreements(repo, path) do
    migrations = migration_status(repo, path)
    carried = carried_versions(path)

    {for({:down, version, _name} <- migrations, do: version),
     for({:up, version, _name} <- migrations, not MapSet.member?(carried, version), do: version)}
  end

  defp migration_status(repo, path) do
    case read_migration_status(repo, path) do
      {:ok, migrations} -> migrations
      :no_migration_table -> raise @missing_migration_table_error
    end
  end

  defp read_migration_status(repo, path) do
    {:ok,
     Ecto.Migrator.migrations(repo, [path],
       prefix: repo.default_prefix(),
       skip_table_creation: true,
       migration_lock: false
     )}
  rescue
    error in Postgrex.Error ->
      if undefined_migration_table?(error, migration_source(repo)) do
        :no_migration_table
      else
        reraise error, __STACKTRACE__
      end
  end

  defp undefined_migration_table?(
         %Postgrex.Error{postgres: %{code: :undefined_table, message: message}},
         source
       ),
       do: String.contains?(message, source)

  defp undefined_migration_table?(_error, _source), do: false

  # Ecto names an applied version with no file after a placeholder marker. The
  # set of versions the release actually carries answers the same question
  # without depending on that marker's text.
  defp carried_versions(path) do
    path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      case file |> Path.basename() |> Integer.parse() do
        {version, "_" <> _name} -> [version]
        _unversioned -> []
      end
    end)
    |> MapSet.new()
  end

  defp report([], [], []), do: IO.puts("none")

  defp report(pending, applied_without_file, shared) do
    if pending != [], do: IO.puts("pending: #{Enum.join(pending, " ")}")

    if applied_without_file != [] do
      IO.puts("applied-without-file: #{Enum.join(applied_without_file, " ")}")
    end

    if shared != [], do: IO.puts("shared-pending: #{Enum.join(shared, ", ")}")
  end

  defp migration_source(repo), do: repo.config()[:migration_source] || "schema_migrations"

  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end

  defp migrations_path do
    Application.app_dir(@app, "priv/repo/migrations")
  end
end
