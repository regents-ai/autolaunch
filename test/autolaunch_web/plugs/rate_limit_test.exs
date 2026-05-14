defmodule AutolaunchWeb.Plugs.RateLimitTest do
  use AutolaunchWeb.ConnCase, async: false

  alias AutolaunchWeb.RateLimiter

  @agent_claims %{
    "wallet_address" => "0x1111111111111111111111111111111111111111",
    "chain_id" => "8453",
    "registry_address" => "0x2222222222222222222222222222222222222222",
    "token_id" => "99"
  }

  setup do
    original = Application.get_env(:autolaunch, :rate_limits, [])
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:autolaunch, :rate_limits, original)
      RateLimiter.reset()
    end)

    :ok
  end

  test "public write routes are rate limited", %{conn: conn} do
    Application.put_env(:autolaunch, :rate_limits,
      public_write: [limit: 1, window_ms: 60_000],
      expensive_read: [limit: 50, window_ms: 60_000]
    )

    post(conn, "/v1/app/agentbook/sessions", %{"network" => "world"})
    conn = post(conn, "/v1/app/agentbook/sessions", %{"network" => "world"})

    assert %{"ok" => false, "error" => %{"code" => "rate_limited"}} =
             json_response(conn, 429)

    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  test "expensive read routes are rate limited", %{conn: conn} do
    Application.put_env(:autolaunch, :rate_limits,
      public_write: [limit: 50, window_ms: 60_000],
      expensive_read: [limit: 1, window_ms: 60_000]
    )

    get(conn, "/v1/app/me/profile")
    conn = get(conn, "/v1/app/me/profile")

    assert %{"ok" => false, "error" => %{"code" => "rate_limited"}} =
             json_response(conn, 429)

    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  test "signed-agent limits are keyed by verified agent claims" do
    Application.put_env(:autolaunch, :rate_limits,
      signed_agent_write: [limit: 1, window_ms: 60_000],
      public_write: [limit: 50, window_ms: 60_000],
      expensive_read: [limit: 50, window_ms: 60_000]
    )

    first =
      :post
      |> build_conn("/v1/agent/subjects")
      |> assign(:current_agent_claims, @agent_claims)
      |> AutolaunchWeb.Plugs.RateLimit.call([])

    refute first.halted

    second =
      :post
      |> build_conn("/v1/agent/subjects")
      |> assign(:current_agent_claims, @agent_claims)
      |> AutolaunchWeb.Plugs.RateLimit.call([])

    assert second.halted
    assert get_resp_header(second, "retry-after") == ["60"]

    third =
      :post
      |> build_conn("/v1/agent/subjects")
      |> assign(:current_agent_claims, %{@agent_claims | "token_id" => "100"})
      |> AutolaunchWeb.Plugs.RateLimit.call([])

    refute third.halted
  end

  test "spoofed CLI headers remain on the public allowance" do
    Application.put_env(:autolaunch, :rate_limits,
      public_write: [limit: 1, window_ms: 60_000],
      signed_agent_write: [limit: 50, window_ms: 60_000],
      expensive_read: [limit: 50, window_ms: 60_000]
    )

    first =
      :post
      |> build_conn("/v1/agent/subjects")
      |> put_req_header("x-regents-client", "regents-cli")
      |> put_req_header("x-regents-cli-version", "0.5.0")
      |> AutolaunchWeb.Plugs.RateLimit.call([])

    refute first.halted

    second =
      :post
      |> build_conn("/v1/agent/subjects")
      |> put_req_header("x-regents-client", "regents-cli")
      |> put_req_header("x-regents-cli-version", "0.5.0")
      |> AutolaunchWeb.Plugs.RateLimit.call([])

    assert second.halted
    assert get_resp_header(second, "retry-after") == ["60"]
  end

  test "health checks are not rate limited", %{conn: conn} do
    Application.put_env(:autolaunch, :rate_limits,
      public_write: [limit: 1, window_ms: 60_000],
      expensive_read: [limit: 1, window_ms: 60_000]
    )

    get(conn, "/health")
    conn = get(conn, "/health")

    assert json_response(conn, 200) == %{"ok" => true, "service" => "autolaunch"}
  end
end
