defmodule AutolaunchWeb.ApiRoutesTest do
  use AutolaunchWeb.ConnCase, async: false

  alias AutolaunchWeb.Api.RegentStakingController

  @app_only_product_routes [
    {:post, "/regent/staking/deposit-usdc/prepare", RegentStakingController, :prepare_deposit},
    {:post, "/regent/staking/withdraw-treasury/prepare", RegentStakingController,
     :prepare_withdraw_treasury}
  ]

  @public_app_routes [
    {:post, "/agentbook/sessions"},
    {:get, "/agentbook/sessions/:id"},
    {:post, "/agentbook/sessions/:id/submit"},
    {:get, "/agentbook/lookup"},
    {:post, "/agentbook/verify"}
  ]

  test "root serves the landing homepage", %{conn: conn} do
    conn = get(conn, "/")
    html = html_response(conn, 200)

    assert html =~ "Turn agent edge into runway."
    assert html =~ "Launch and grow agent economies"
    assert html =~ "Explore auctions"
    assert html =~ "Tokens live"
  end

  test "auction index returns JSON", %{conn: conn} do
    conn = get(conn, "/v1/app/auctions")

    assert %{"ok" => true, "items" => items} = json_response(conn, 200)
    assert is_list(items)
  end

  test "launch preview requires auth", %{conn: conn} do
    conn =
      post(conn, "/v1/app/launch/preview", %{
        "agent_id" => "ag_research",
        "token_name" => "Agent Coin",
        "token_symbol" => "AGENT",
        "agent_safe_address" => "0x0000000000000000000000000000000000000001"
      })

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} = json_response(conn, 401)
  end

  test "ens link planner requires auth", %{conn: conn} do
    conn =
      post(conn, "/v1/app/ens/link/plan", %{
        "ens_name" => "vitalik.eth",
        "chain_id" => "1",
        "agent_id" => "42"
      })

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} = json_response(conn, 401)
  end

  test "subject routes are wired", %{conn: conn} do
    conn = get(conn, "/v1/app/subjects/not-a-valid-subject")

    assert %{"ok" => false, "error" => %{"code" => "invalid_subject_id"}} =
             json_response(conn, 422)
  end

  test "app and agent product API routes stay paired" do
    app_routes =
      "/v1/app"
      |> product_route_specs()
      |> Enum.reject(&public_app_route?/1)
      |> Enum.reject(&app_only_product_route?/1)
      |> normalize_route_specs("/v1/app")

    agent_routes =
      "/v1/agent"
      |> product_route_specs()
      |> normalize_route_specs("/v1/agent")

    assert app_routes == agent_routes
  end

  test "app-only staking preparation routes stay out of the agent API" do
    app_routes = product_route_specs("/v1/app")
    agent_routes = product_route_specs("/v1/agent")

    for route <- @app_only_product_routes do
      assert route in normalize_route_specs(app_routes, "/v1/app")
      refute route in normalize_route_specs(agent_routes, "/v1/agent")
    end
  end

  defp product_route_specs(prefix) do
    AutolaunchWeb.Router.__routes__()
    |> Enum.filter(&String.starts_with?(&1.path, prefix))
    |> Enum.map(&route_spec/1)
    |> Enum.sort()
  end

  defp route_spec(route), do: {route.verb, route.path, route.plug, route.plug_opts}

  defp normalize_route_specs(route_specs, prefix) do
    route_specs
    |> Enum.map(fn {verb, path, plug, plug_opts} ->
      {verb, String.replace_prefix(path, prefix, ""), plug, plug_opts}
    end)
    |> Enum.sort()
  end

  defp public_app_route?({verb, path, _plug, _plug_opts}) do
    {verb, String.replace_prefix(path, "/v1/app", "")} in @public_app_routes
  end

  defp app_only_product_route?({verb, path, plug, plug_opts}) do
    {verb, String.replace_prefix(path, "/v1/app", ""), plug, plug_opts} in @app_only_product_routes
  end
end
