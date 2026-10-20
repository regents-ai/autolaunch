defmodule Autolaunch.Release do
  @moduledoc false

  @app :autolaunch
  @platform_schema "regent_names"

  @table_exists """
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'p')
  )
  """
  @schema_exists "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = $1)"

  # Every shared library with its own schema and ledger, in the order their
  # changes apply: Credits' pairing grants build on Agents' pairing history.
  @shared [
    {:regent_identity, "regent_identity", RegentIdentity.Migrator},
    {:regent_agents, "regent_agents", RegentAgents.Migrator},
    {:regent_credits, "regent_credits", RegentCredits.Migrator},
    {:regent_points, "regent_points", RegentPoints.Migrator},
    {:regent_payments, "regent_payments", RegentPayments.Migrator}
  ]

  def migration_config!(getenv \\ &System.get_env/1) do
    getenv
    |> Autolaunch.DatabaseConfig.release_config!()
    |> Keyword.merge(
      default_prefix: Autolaunch.Repo.default_prefix(),
      migration_default_prefix: Autolaunch.Repo.default_prefix()
    )
  end

  def migrate do
    with_release_repo([], fn repo ->
      require_signed_access_schema!(repo)
      migrate_site!(repo, migrations_path())
    end)
  end

  @doc """
  Applies the shared database changes this release's pinned libraries carry
  that the database has not applied, and prints each one, or `none`. Run as
  `/app/bin/migrate-shared`.

  Every site carries this same command. A deployment never runs it: `migrate/0`
  refuses while a shared change is missing and applies none. Each change needs
  the founder's own named go; the site whose release first carries it runs this
  from the new image before that deployment, because only that image carries
  the change's file. Each library's ledger takes a migration lock, so two sites
  running it at once apply each change once. Its options are the bootstrap's.
  """
  def migrate_shared(opts \\ []) when is_list(opts) do
    applied =
      with_release_repo(opts, fn repo ->
        unapplied = unapplied_shared_migrations(repo)
        if unapplied != [], do: apply_shared(repo)
        unapplied
      end)

    case applied do
      [] -> IO.puts("none")
      applied -> IO.puts("applied: #{Enum.join(applied, ", ")}")
    end
  end

  @doc """
  Undoes this site's own migrations from the newest back to and including
  `version`, the way `migrate/0` applies them. The database is shared by every Regent site,
  so going back to an earlier version is done this way, never by restoring it.
  """
  def rollback(version) when is_integer(version) do
    with_release_repo([], fn repo ->
      Ecto.Migrator.run(repo, migrations_path(), :down,
        to: version,
        prefix: repo.default_prefix()
      )
    end)
  end

  @doc "Read-only release prerequisite; shared migrations require separate founder authority."
  def require_signed_access_schema!(repo) do
    :ok = require_shared_migrations!(repo)
    :ok = RegentAgents.Migrator.require_pairing_history!(repo)
    RegentCredits.Migrator.require_pairing_grants!(repo)
  end

  # The shared code this release carries reads tables and columns from every
  # migration its pinned library ships, so each must already be in that schema's
  # own ledger. Every missing version is named at once.
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
    for {app, schema, _migrator} <- carried_shared(),
        version <-
          unapplied_versions(repo, schema, Application.app_dir(app, "priv/repo/migrations")),
        do: "#{schema} #{version}"
  end

  # A read only: with its table creation skipped and no migration lock the
  # migrator just selects the schema's ledger. A library whose ledger does not
  # exist yet has had none of its changes applied.
  defp unapplied_versions(repo, schema, path) do
    if table_exists?(repo, schema, "schema_migrations") do
      for {:down, version, _name} <-
            Ecto.Migrator.migrations(repo, [path],
              prefix: schema,
              skip_table_creation: true,
              migration_lock: false
            ),
          do: version
    else
      Enum.sort(carried_versions(path))
    end
  end

  @doc "Creates the product schema when the database does not have it yet."
  def ensure_schema!(repo) do
    repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{repo.default_prefix()}"), [])
    :ok
  end

  @doc """
  Prepares an empty staging database for the first deployment: creates a
  staging-only copy of the tables this repository reads but does not own
  (`regent_names.platform_human_users`), in the local fixture's shape, applies
  every shared change this release carries, as `migrate_shared/0` does in
  production, then runs every migration into `autolaunch_app`
  (`prepare_database!/2`). It refuses a database that already carries migration
  state or the regent_names schema and repairs nothing: recovery from a
  half-finished bootstrap is to destroy and recreate the staging database.

  The deployed launcher passes no options, so it reads only the database the
  release configuration resolves. The options (`:getenv`, `:config`,
  `:migrations_path`) aim it at a disposable database under test.
  """
  def bootstrap_staging(opts \\ []) when is_list(opts) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)

    # Read before anything opens a connection, so no configuration mistake can
    # point this command at a database outside staging.
    if getenv.("AUTOLAUNCH_DEPLOYMENT_ROLE") != "staging",
      do: raise("bootstrap-staging requires AUTOLAUNCH_DEPLOYMENT_ROLE to be exactly staging")

    with_release_repo(opts, fn repo ->
      refuse_existing_state!(repo)
      prepare_database!(repo, migrations_directory(opts))
    end)
  end

  @doc false
  # Staging's first deployment and every local database
  # (`Autolaunch.LocalDatabaseFixture`) are prepared the same way, in
  # production's order: the tables this repository reads but does not own (the
  # fixture is the only definition of their shape), every shared change this
  # release carries, then this site's own migrations.
  def prepare_database!(repo, path \\ migrations_path()) do
    Autolaunch.LocalDatabaseFixture.create_shared_tables!()
    apply_shared(repo)
    migrate_site!(repo, path)
  end

  # Every Autolaunch table and the migration ledger live in the product schema.
  defp migrate_site!(repo, path) do
    ensure_schema!(repo)
    Ecto.Migrator.run(repo, path, :up, all: true, prefix: repo.default_prefix())
  end

  @doc """
  Prints what a deployed database and the release disagree about: the migrations
  the release carries that the database has not applied (`pending:`), the
  versions the database has applied whose file the release does not carry
  (`applied-without-file:`), and the shared changes the release carries that
  their own ledgers do not hold (`shared-pending:`, each as schema and version;
  a deployment is refused while one is listed, and `migrate_shared/0` applies
  them), or `none`.
  It applies nothing, creates nothing, and takes no migration lock. Its options
  are the bootstrap's.
  """
  def pending_migrations(opts \\ []) when is_list(opts) do
    {pending, applied_without_file, shared} =
      with_release_repo(opts, fn repo ->
        {pending, applied_without_file} = disagreements(repo, migrations_directory(opts))
        {pending, applied_without_file, unapplied_shared_migrations(repo)}
      end)

    if pending == [] and applied_without_file == [] and shared == [], do: IO.puts("none")
    if pending != [], do: IO.puts("pending: #{Enum.join(pending, " ")}")

    if applied_without_file != [],
      do: IO.puts("applied-without-file: #{Enum.join(applied_without_file, " ")}")

    if shared != [], do: IO.puts("shared-pending: #{Enum.join(shared, ", ")}")
  end

  defp disagreements(repo, path) do
    prefix = repo.default_prefix()

    unless table_exists?(repo, prefix, migration_source(repo)),
      do: raise("no schema_migrations table: run bootstrap-staging first")

    migrations =
      Ecto.Migrator.migrations(repo, [path],
        prefix: prefix,
        skip_table_creation: true,
        migration_lock: false
      )

    carried = carried_versions(path)

    {for({:down, version, _name} <- migrations, do: version),
     for({:up, version, _name} <- migrations, version not in carried, do: version)}
  end

  # Ecto names an applied version with no file after a placeholder marker. The
  # set of versions the release actually carries answers the same question
  # without depending on that marker's text.
  defp carried_versions(path) do
    for file <- Path.wildcard(Path.join(path, "*.exs")),
        {version, "_" <> _name} <- [file |> Path.basename() |> Integer.parse()],
        into: MapSet.new(),
        do: version
  end

  defp apply_shared(repo), do: Enum.each(carried_shared(), fn {_, _, m} -> m.up(repo) end)

  # A shared library this site does not carry has no tables it reads or changes.
  defp carried_shared do
    carried = Application.spec(@app, :applications)
    for {app, _schema, _migrator} = shared <- @shared, app in carried, do: shared
  end

  defp refuse_existing_state!(repo) do
    prefix = repo.default_prefix()
    source = migration_source(repo)

    if table_exists?(repo, prefix, source) do
      raise "#{prefix}.#{source} already exists: destroy and recreate the staging database"
    end

    if schema_exists?(repo, @platform_schema) do
      raise "#{@platform_schema} schema already exists: destroy and recreate the staging database"
    end
  end

  defp table_exists?(repo, prefix, table) do
    %{rows: [[exists?]]} = Ecto.Adapters.SQL.query!(repo, @table_exists, [prefix, table])
    exists?
  end

  defp schema_exists?(repo, schema) do
    %{rows: [[exists?]]} = Ecto.Adapters.SQL.query!(repo, @schema_exists, [schema])
    exists?
  end

  defp migration_source(repo), do: repo.config()[:migration_source] || "schema_migrations"

  # Loads the app and starts only its database connection, on the release
  # login with the product schema unless `:config` names another, for as long
  # as `fun` runs; returns what `fun` returns.
  defp with_release_repo(opts, fun) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)
    :ok = Application.ensure_loaded(@app)
    config = Keyword.get_lazy(opts, :config, fn -> migration_config!(getenv) end)
    Application.put_env(@app, Autolaunch.Repo, config)
    {:ok, result, _started} = Ecto.Migrator.with_repo(Autolaunch.Repo, fun)
    result
  end

  defp migrations_directory(opts),
    do: Keyword.get_lazy(opts, :migrations_path, &migrations_path/0)

  defp migrations_path, do: Application.app_dir(@app, "priv/repo/migrations")
end
