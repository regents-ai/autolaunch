defmodule Autolaunch.Health do
  @moduledoc """
  Whether the site's own database answers, for the health check, and whether
  every migration this release carries is applied.
  """

  # Validate a real product read without returning user rows. The timeout is
  # below Fly's two-second health deadline, and no error/connection data leaves
  # this check. A running BEAM alone does not make the application ready.
  # The prefix is the repository's own configured schema name, never request input.
  # sobelow_skip ["SQL.Query"]
  def database_ready? do
    case Ecto.Adapters.SQL.query(
           Autolaunch.Repo,
           "SELECT 1 FROM \"#{Autolaunch.Repo.default_prefix()}\".auctions LIMIT 0",
           [],
           timeout: 1_000,
           log: false
         ) do
      {:ok, _result} -> true
      {:error, _error} -> false
    end
  rescue
    # A repository that is not running raises or exits instead of answering;
    # the check still answers that the site is not ready.
    _error -> false
  catch
    :exit, _reason -> false
  end

  @doc """
  True when every migration file this release carries is recorded in the site's
  own schema. It only reads: no lock, and it never creates the ledger. A
  database that does not answer is `false`.
  """
  def migrations_applied? do
    Autolaunch.Repo
    |> Ecto.Migrator.migrations([Application.app_dir(:autolaunch, "priv/repo/migrations")],
      prefix: Autolaunch.Repo.default_prefix(),
      skip_table_creation: true,
      migration_lock: false,
      timeout: 1_000,
      log: false
    )
    |> Enum.all?(&match?({:up, _version, _name}, &1))
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end
end
