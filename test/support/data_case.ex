defmodule Autolaunch.DataCase do
  @moduledoc "Test support for cases that reach the database through the SQL sandbox."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query

      alias Autolaunch.Repo
    end
  end

  setup tags do
    Autolaunch.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Checks out a sandboxed connection for the test.

  A synchronous test shares its connection with every process it starts; an
  asynchronous one keeps the connection to itself.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Autolaunch.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
