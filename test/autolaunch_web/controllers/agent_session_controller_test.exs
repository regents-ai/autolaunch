defmodule AutolaunchWeb.AgentSessionControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  @wallet_address "0x1111111111111111111111111111111111111111"
  @chain_id "84532"
  @registry_address "0x2222222222222222222222222222222222222222"
  @token_id "44"

  setup_all do
    original_siwa_cfg = Application.get_env(:autolaunch, :siwa, [])
    port = available_port()

    start_supervised!(
      {Bandit,
       plug: Autolaunch.TestSupport.SiwaBrokerStub, ip: {127, 0, 0, 1}, port: port}
    )

    Application.put_env(:autolaunch, :siwa,
      internal_url: "http://127.0.0.1:#{port}",
      http_connect_timeout_ms: 2_000,
      http_receive_timeout_ms: 5_000
    )

    on_exit(fn -> Application.put_env(:autolaunch, :siwa, original_siwa_cfg) end)

    :ok
  end

  test "create, show, and delete keep the full verified agent identity in the local app session", %{
    conn: conn
  } do
    created_conn =
      conn
      |> init_test_session(%{})
      |> with_agent_headers()
      |> post("/api/auth/agent/session", %{})

    created = json_response(created_conn, 200)

    assert created["ok"] == true
    assert created["session"]["audience"] == "autolaunch"
    assert created["session"]["wallet_address"] == @wallet_address
    assert created["session"]["chain_id"] == @chain_id
    assert created["session"]["registry_address"] == @registry_address
    assert created["session"]["token_id"] == @token_id
    assert is_binary(created["session"]["session_id"])

    show_conn =
      created_conn
      |> recycle()
      |> get("/api/auth/agent/session")

    shown = json_response(show_conn, 200)

    assert shown["ok"] == true
    assert shown["session"]["session_id"] == created["session"]["session_id"]
    assert shown["session"]["registry_address"] == @registry_address
    assert shown["session"]["token_id"] == @token_id

    delete_conn =
      show_conn
      |> recycle()
      |> delete("/api/auth/agent/session")

    assert %{"ok" => true} = json_response(delete_conn, 200)

    cleared_conn =
      delete_conn
      |> recycle()
      |> get("/api/auth/agent/session")

    assert %{"ok" => true, "session" => nil} = json_response(cleared_conn, 200)
  end

  test "agent-only session creation works without a linked human account", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> with_agent_headers()
      |> post("/api/auth/agent/session", %{})

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert response["session"]["wallet_address"] == @wallet_address
    assert response["session"]["registry_address"] == @registry_address
    assert response["session"]["token_id"] == @token_id
  end

  defp with_agent_headers(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-agent-wallet-address", @wallet_address)
    |> put_req_header("x-agent-chain-id", @chain_id)
    |> put_req_header("x-agent-registry-address", @registry_address)
    |> put_req_header("x-agent-token-id", @token_id)
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
