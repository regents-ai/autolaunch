defmodule Autolaunch.DatabaseFaults do
  @moduledoc """
  A lost database connection, made at a chosen moment in a request: the case's
  own sandboxed connection is cut (`pg_terminate_backend`, from a second
  connection), as it would be if the database went away just then
  (`cut_when/2`) or between two requests (`cut_now/0`), or one table's reads answer as a lost connection while the
  connection itself keeps working (`lose_reads_of/1`), as when one pooled
  connection is lost and the next is healthy. Only a synchronous ConnCase may
  use them.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias Autolaunch.Repo

  @doc """
  Cuts this case's database connection the first time `event` fires in this
  process with metadata `cut?` accepts.
  """
  def cut_when(event, cut?) do
    test = self()
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

    cutter =
      start_supervised!(
        {Postgrex,
         Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])}
      )

    handler = "cut-#{inspect(test)}"

    :telemetry.attach(
      handler,
      event,
      fn _event, _measurements, metadata, _config ->
        if self() == test and cut?.(metadata) do
          :telemetry.detach(handler)
          Postgrex.query!(cutter, "SELECT pg_terminate_backend($1)", [backend])
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc """
  Cuts this case's database connection now, as if the database went away
  between two requests: the next statement on it, even the start of a
  transaction, fails with the connection's own error.
  """
  def cut_now do
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

    cutter =
      start_supervised!(
        Supervisor.child_spec(
          {Postgrex,
           Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])},
          id: make_ref()
        )
      )

    Postgrex.query!(cutter, "SELECT pg_terminate_backend($1)", [backend])
  end

  @doc """
  Every read of `table` (in `autolaunch_app`) answers as a lost database
  connection (SQLSTATE 08006, connection failure) until `restore_reads_of/1`,
  while the case's connection itself keeps working, so writes and other reads
  still go through. Lasts only as long as the case's sandboxed transaction.
  """
  def lose_reads_of(table) do
    Repo.query!(~s|ALTER TABLE autolaunch_app."#{table}" RENAME TO "#{table}_kept"|)

    Repo.query!("""
    CREATE FUNCTION autolaunch_app.lost_read() RETURNS SETOF autolaunch_app."#{table}_kept"
    LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'connection lost' USING ERRCODE = '08006'; END
    $$
    """)

    Repo.query!(
      ~s|CREATE VIEW autolaunch_app."#{table}" AS SELECT * FROM autolaunch_app.lost_read()|
    )
  end

  @doc "Puts `table` back after `lose_reads_of/1`."
  def restore_reads_of(table) do
    Repo.query!(~s|DROP VIEW autolaunch_app."#{table}"|)
    Repo.query!("DROP FUNCTION autolaunch_app.lost_read()")
    Repo.query!(~s|ALTER TABLE autolaunch_app."#{table}_kept" RENAME TO "#{table}"|)
  end
end
