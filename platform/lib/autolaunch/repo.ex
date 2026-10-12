defmodule Autolaunch.Repo do
  use AshPostgres.Repo,
    otp_app: :autolaunch

  @impl true
  def default_prefix do
    Application.fetch_env!(:autolaunch, __MODULE__) |> Keyword.fetch!(:default_prefix)
  end

  @impl true
  def default_options(_operation), do: [prefix: default_prefix()]

  # PostgreSQL's own catalog (`pg_class`, `pg_namespace`, ...) is never in this
  # schema, so a read of it drops the default above. ErrorTracker's migration
  # reads it.
  @impl true
  def prepare_query(_operation, %{from: %{source: {"pg_" <> _table, nil}}} = query, opts),
    do: {query, Keyword.delete(opts, :prefix)}

  def prepare_query(_operation, query, opts), do: {query, opts}

  @impl true
  # pg_trgm scores how closely a search matches, typos included (`Autolaunch.Search`).
  def installed_extensions do
    ["ash-functions", "pg_trgm"]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def min_pg_version do
    %Version{major: 14, minor: 20, patch: 0}
  end
end
