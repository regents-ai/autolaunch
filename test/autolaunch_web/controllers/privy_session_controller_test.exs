defmodule AutolaunchWeb.PrivySessionControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  defmodule PrivyStub do
    def verify_token("good-token"), do: {:ok, %{privy_user_id: "did:privy:session"}}
    def verify_token(_token), do: {:error, :invalid_token}
  end

  defmodule PortfolioStub do
    def schedule_login_refresh(human) do
      if pid = Application.get_env(:autolaunch, :portfolio_schedule_test_pid) do
        send(pid, {:scheduled_portfolio_refresh, human.privy_user_id})
      end

      :ok
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :privy_session_controller, [])

    Application.put_env(
      :autolaunch,
      :privy_session_controller,
      privy_module: PrivyStub,
      portfolio_module: PortfolioStub
    )

    Application.put_env(:autolaunch, :portfolio_schedule_test_pid, self())

    on_exit(fn ->
      Application.put_env(:autolaunch, :privy_session_controller, original)
      Application.delete_env(:autolaunch, :portfolio_schedule_test_pid)
    end)

    :ok
  end

  test "create logs the human in and schedules a portfolio refresh", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer good-token")
      |> post("/api/auth/privy/session", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "display_name" => "Operator"
      })

    assert %{"ok" => true, "human" => %{"privy_user_id" => "did:privy:session"}} =
             json_response(conn, 200)

    assert_received {:scheduled_portfolio_refresh, "did:privy:session"}
  end
end
