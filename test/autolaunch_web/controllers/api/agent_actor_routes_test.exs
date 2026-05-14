defmodule AutolaunchWeb.Api.AgentActorRoutesTest do
  use AutolaunchWeb.ConnCase, async: false

  @wallet "0x1111111111111111111111111111111111111111"
  @registry "0x2222222222222222222222222222222222222222"
  @token_id "44"
  @receipt_secret "autolaunch-test-receipt-secret"

  defmodule PrelaunchStub do
    def create_plan(_params, %{"wallet_address" => wallet}), do: {:ok, %{actor_wallet: wallet}}
  end

  defmodule LaunchStub do
    def preview_launch(_params, %{"wallet_address" => wallet}), do: {:ok, %{actor_wallet: wallet}}
  end

  defmodule LifecycleStub do
    def prepare_finalize(_job_id, %{"wallet_address" => wallet}),
      do: {:ok, %{actor_wallet: wallet}}
  end

  defmodule SubjectStub do
    def stake(_subject_id, _params, %{"wallet_address" => wallet}),
      do: {:ok, %{actor_wallet: wallet}}
  end

  setup %{conn: conn} do
    original_siwa = Application.get_env(:autolaunch, :siwa, [])
    original_prelaunch = Application.get_env(:autolaunch, :prelaunch_api, [])
    original_launch = Application.get_env(:autolaunch, :launch_controller, [])
    original_lifecycle = Application.get_env(:autolaunch, :lifecycle_api, [])
    original_subject = Application.get_env(:autolaunch, :subject_api, [])
    port = available_port()

    start_supervised!(
      {Bandit, plug: Autolaunch.TestSupport.SiwaBrokerStub, ip: {127, 0, 0, 1}, port: port}
    )

    Application.put_env(:autolaunch, :siwa,
      internal_url: "http://127.0.0.1:#{port}",
      http_connect_timeout_ms: 2_000,
      http_receive_timeout_ms: 5_000
    )

    Application.put_env(:autolaunch, :prelaunch_api, context_module: PrelaunchStub)
    Application.put_env(:autolaunch, :launch_controller, launch_module: LaunchStub)
    Application.put_env(:autolaunch, :lifecycle_api, context_module: LifecycleStub)
    Application.put_env(:autolaunch, :subject_api, context_module: SubjectStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :siwa, original_siwa)
      Application.put_env(:autolaunch, :prelaunch_api, original_prelaunch)
      Application.put_env(:autolaunch, :launch_controller, original_launch)
      Application.put_env(:autolaunch, :lifecycle_api, original_lifecycle)
      Application.put_env(:autolaunch, :subject_api, original_subject)
    end)

    %{conn: with_agent_headers(conn)}
  end

  test "agent prelaunch routes use the signed agent identity", %{conn: conn} do
    conn = post(conn, "/v1/agent/prelaunch/plans", %{"agent_id" => "84532:44"})

    assert %{"ok" => true, "plan" => %{"actor_wallet" => @wallet}} = json_response(conn, 201)
  end

  test "agent launch routes use the signed agent identity", %{conn: conn} do
    conn = post(conn, "/v1/agent/launch/preview", %{"agent_id" => "84532:44"})

    assert %{"ok" => true, "preview" => %{"actor_wallet" => @wallet}} =
             json_response(conn, 200)
  end

  test "agent lifecycle routes use the signed agent identity", %{conn: conn} do
    conn = post(conn, "/v1/agent/lifecycle/jobs/job_1/finalize/prepare", %{})

    assert %{"ok" => true, "actor_wallet" => @wallet} = json_response(conn, 200)
  end

  test "agent subject write routes use the signed agent identity", %{conn: conn} do
    conn = post(conn, "/v1/agent/subjects/subj_1/stake", %{"amount" => "1"})

    assert %{"ok" => true, "actor_wallet" => @wallet} = json_response(conn, 200)
  end

  defp with_agent_headers(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-agent-wallet-address", @wallet)
    |> put_req_header("x-agent-chain-id", "84532")
    |> put_req_header("x-agent-registry-address", @registry)
    |> put_req_header("x-agent-token-id", @token_id)
    |> put_req_header("x-siwa-receipt", receipt_token("autolaunch"))
  end

  defp receipt_token(audience) do
    now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    payload =
      %{
        "typ" => "siwa_receipt",
        "jti" => Ecto.UUID.generate(),
        "sub" => @wallet,
        "aud" => audience,
        "verified" => "onchain",
        "iat" => now_ms,
        "exp" => now_ms + 600_000,
        "chain_id" => 84_532,
        "nonce" => "nonce-#{System.unique_integer([:positive])}",
        "key_id" => @wallet,
        "registry_address" => @registry,
        "token_id" => @token_id
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
