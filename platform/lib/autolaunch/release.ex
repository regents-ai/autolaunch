defmodule Autolaunch.Release do
  @moduledoc false

  @app :autolaunch
  @imported_through 20_260_904_001_517
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
      require_imported_history!(repo)
      Ecto.Migrator.run(repo, migrations_path(), :up, all: true, prefix: repo.default_prefix())
    end)
  end

  @doc """
  Initializes a specifically approved empty product database.

  Historical migrations first run in an empty `public` schema because their
  generated foreign keys name that schema explicitly. The resulting tables,
  sequences and honest migration ledger are then moved together into the
  configured product schema. This command refuses an initialized destination.
  """
  def bootstrap do
    load_app()
    config = migration_config!()
    target_prefix = Keyword.fetch!(config, :default_prefix)

    unless target_prefix == "autolaunch_app" do
      raise "Autolaunch bootstrap requires AUTOLAUNCH_DB_SCHEMA=autolaunch_app"
    end

    public_config =
      config
      |> Keyword.put(:default_prefix, "public")
      |> Keyword.put(:migration_default_prefix, "public")

    Application.put_env(@app, Autolaunch.Repo, public_config)

    Ecto.Migrator.with_repo(Autolaunch.Repo, fn repo ->
      require_empty_bootstrap_destination!(repo, target_prefix)
      Ecto.Migrator.run(repo, migrations_path(), :up, all: true, prefix: "public")
      move_bootstrapped_product!(repo, target_prefix)
    end)

    Application.put_env(@app, Autolaunch.Repo, config)

    Ecto.Migrator.with_repo(Autolaunch.Repo, fn repo ->
      RegentIdentity.Migrator.up(repo)
    end)
  end

  @doc """
  Lists what a deployed database and the release disagree about.

  Prints every migration the release carries that the database has not applied
  under `pending:`, and every version the database has applied whose file the
  release does not carry under `applied-without-file:`. Prints `none` when both
  are empty. It applies nothing, creates nothing, and takes no migration lock.
  """
  def pending_migrations do
    load_app()
    Application.put_env(@app, Autolaunch.Repo, migration_config!())
    path = migrations_path()

    {:ok, {pending, applied_without_file}, _started} =
      Ecto.Migrator.with_repo(Autolaunch.Repo, fn repo ->
        collect_disagreements(repo, path)
      end)

    report(pending, applied_without_file)
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

  defp report([], []), do: IO.puts("none")

  defp report(pending, applied_without_file) do
    if pending != [], do: IO.puts("pending: #{Enum.join(pending, " ")}")

    if applied_without_file != [] do
      IO.puts("applied-without-file: #{Enum.join(applied_without_file, " ")}")
    end
  end

  defp migration_source(repo), do: repo.config()[:migration_source] || "schema_migrations"

  defp require_imported_history!(repo) do
    if repo.default_prefix() != "public" do
      incomplete? =
        repo
        |> migration_status(migrations_path())
        |> Enum.any?(fn {status, version, _name} ->
          status == :down and version <= @imported_through
        end)

      if incomplete? do
        raise "Import the complete Autolaunch schema and migration history before migrating"
      end
    end
  end

  defp require_empty_bootstrap_destination!(repo, target_prefix) do
    expected_database = System.fetch_env!("AUTOLAUNCH_BOOTSTRAP_DATABASE")
    %{rows: [[actual_database]]} = repo.query!("SELECT current_database()", [])

    unless actual_database == expected_database do
      raise "Autolaunch bootstrap database does not match AUTOLAUNCH_BOOTSTRAP_DATABASE"
    end

    %{rows: [[public_tables]]} =
      repo.query!(
        """
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
        """,
        []
      )

    %{rows: [[target_objects]]} =
      repo.query!(
        """
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
        """,
        [target_prefix]
      )

    if public_tables != 0 or target_objects != 0 do
      raise "Autolaunch bootstrap requires empty public and autolaunch_app product schemas"
    end
  end

  defp move_bootstrapped_product!(repo, target_prefix) do
    repo.transaction(fn ->
      repo.query!("CREATE SCHEMA \"#{target_prefix}\"", [])
      move_relations!(repo, target_prefix, ["r", "p"])
      move_relations!(repo, target_prefix, ["S"])
    end)
  end

  defp move_relations!(repo, target_prefix, kinds) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind = ANY($1)
        ORDER BY c.relname
        """,
        [kinds]
      )

    Enum.each(rows, fn [name] ->
      kind = if "S" in kinds, do: "SEQUENCE", else: "TABLE"
      repo.query!("ALTER #{kind} \"public\".\"#{name}\" SET SCHEMA \"#{target_prefix}\"", [])
    end)
  end

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
