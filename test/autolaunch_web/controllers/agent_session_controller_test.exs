defmodule AutolaunchWeb.AgentSessionControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  @wallet_address "0x1111111111111111111111111111111111111111"
  @chain_id "84532"
  @registry_address "0x2222222222222222222222222222222222222222"
  @token_id "44"
  @receipt_secret "autolaunch-test-shared-secret"

  setup_all do
    original_siwa_cfg = Application.get_env(:autolaunch, :siwa, [])
    port = available_port()

    start_supervised!(
      {Bandit, plug: Autolaunch.TestSupport.SiwaBrokerStub, ip: {127, 0, 0, 1}, port: port}
    )

    Application.put_env(:autolaunch, :siwa,
      internal_url: "http://127.0.0.1:#{port}",
      shared_secret: @receipt_secret,
      http_connect_timeout_ms: 2_000,
      http_receive_timeout_ms: 5_000
    )

    on_exit(fn -> Application.put_env(:autolaunch, :siwa, original_siwa_cfg) end)

    :ok
  end

  test "create, show, and delete keep the full verified agent identity in the local app session",
       %{
         conn: conn
       } do
    created_conn =
      conn
      |> init_test_session(%{})
      |> with_agent_headers()
      |> with_csrf()
      |> post("/v1/auth/agent/session", %{})

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
      |> get("/v1/auth/agent/session")

    shown = json_response(show_conn, 200)

    assert shown["ok"] == true
    assert shown["session"]["session_id"] == created["session"]["session_id"]
    assert shown["session"]["registry_address"] == @registry_address
    assert shown["session"]["token_id"] == @token_id

    delete_conn =
      show_conn
      |> recycle()
      |> with_csrf()
      |> delete("/v1/auth/agent/session")

    assert %{"ok" => true} = json_response(delete_conn, 200)

    cleared_conn =
      delete_conn
      |> recycle()
      |> get("/v1/auth/agent/session")

    assert %{"ok" => true, "session" => nil} = json_response(cleared_conn, 200)
  end

  test "agent-only session creation works without a linked human account", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> with_agent_headers()
      |> with_csrf()
      |> post("/v1/auth/agent/session", %{})

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert response["session"]["wallet_address"] == @wallet_address
    assert response["session"]["registry_address"] == @registry_address
    assert response["session"]["token_id"] == @token_id
  end

  test "show clears an expired agent session", %{conn: conn} do
    expired_session = %{
      "session_id" => Ecto.UUID.generate(),
      "audience" => "autolaunch",
      "wallet_address" => @wallet_address,
      "chain_id" => @chain_id,
      "registry_address" => @registry_address,
      "token_id" => @token_id,
      "issued_at" => DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601(),
      "expires_at" => DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    }

    conn =
      conn
      |> init_test_session(%{agent_session: expired_session})
      |> get("/v1/auth/agent/session")

    assert %{"ok" => true, "session" => nil} = json_response(conn, 200)

    followup_conn =
      conn
      |> recycle()
      |> get("/v1/auth/agent/session")

    assert %{"ok" => true, "session" => nil} = json_response(followup_conn, 200)
  end

  test "show clears a malformed local agent session without expiry", %{conn: conn} do
    malformed_session = %{
      "session_id" => Ecto.UUID.generate(),
      "audience" => "autolaunch",
      "wallet_address" => @wallet_address,
      "chain_id" => @chain_id,
      "registry_address" => @registry_address,
      "token_id" => @token_id,
      "issued_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    conn =
      conn
      |> init_test_session(%{agent_session: malformed_session})
      |> get("/v1/auth/agent/session")

    assert %{"ok" => true, "session" => nil} = json_response(conn, 200)
  end

  test "session creation rejects a receipt minted for another app", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> with_agent_headers(receipt_audience: "techtree")
      |> with_csrf()
      |> post("/v1/auth/agent/session", %{})

    assert %{"error" => %{"code" => "siwa_auth_denied"}} = json_response(conn, 401)
  end

  defp with_agent_headers(conn, opts \\ []) do
    wallet_address = Keyword.get(opts, :wallet_address, @wallet_address)
    chain_id = Keyword.get(opts, :chain_id, @chain_id)
    registry_address = Keyword.get(opts, :registry_address, @registry_address)
    token_id = Keyword.get(opts, :token_id, @token_id)
    receipt_audience = Keyword.get(opts, :receipt_audience, "autolaunch")

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-agent-wallet-address", wallet_address)
    |> put_req_header("x-agent-chain-id", chain_id)
    |> put_req_header("x-agent-registry-address", registry_address)
    |> put_req_header("x-agent-token-id", token_id)
    |> put_req_header(
      "x-siwa-receipt",
      receipt_token(wallet_address, chain_id, registry_address, token_id, receipt_audience)
    )
  end

  defp with_csrf(conn) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()
    put_req_header(conn, "x-csrf-token", csrf_token)
  end

  defp receipt_token(wallet_address, chain_id, registry_address, token_id, audience) do
    now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    payload =
      %{
        "typ" => "siwa_receipt",
        "jti" => Ecto.UUID.generate(),
        "sub" => wallet_address,
        "aud" => audience,
        "verified" => "onchain",
        "iat" => now_ms,
        "exp" => now_ms + 600_000,
        "chain_id" => String.to_integer(chain_id),
        "nonce" => "nonce-#{System.unique_integer([:positive])}",
        "key_id" => wallet_address,
        "registry_address" => registry_address,
        "token_id" => token_id
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signature =
      :crypto.mac(:hmac, :sha256, @receipt_secret, payload)
      |> Base.url_encode64(padding: false)

    "#{payload}.#{signature}"
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
