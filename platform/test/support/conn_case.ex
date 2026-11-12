defmodule AutolaunchWeb.ConnCase do
  @moduledoc "Connection and LiveView test support: a bound conn and a sandboxed database connection."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AutolaunchWeb.Endpoint

      use AutolaunchWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
      import Phoenix.LiveViewTest
      import AutolaunchWeb.SessionAuthorityHelpers
    end
  end

  setup tags do
    Autolaunch.DataCase.setup_sandbox(tags)
    {:ok, conn: AutolaunchWeb.SessionAuthorityHelpers.build_conn()}
  end
end
