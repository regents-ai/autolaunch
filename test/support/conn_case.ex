defmodule AutolaunchWeb.ConnCase do
  @moduledoc "Connection test support: a built conn and a sandboxed database connection."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AutolaunchWeb.Endpoint

      use AutolaunchWeb, :verified_routes

      import Phoenix.ConnTest
      import Plug.Conn
    end
  end

  setup tags do
    Autolaunch.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
