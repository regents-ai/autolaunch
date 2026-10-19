defmodule Autolaunch.DatabaseFaults do
  @moduledoc """
  A lost database connection, made at a chosen moment in a request: the case's
  own sandboxed connection is cut (`pg_terminate_backend`, from a second
  connection), as it would be if the database went away just then. Only a
  synchronous ConnCase may use it.
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
end
