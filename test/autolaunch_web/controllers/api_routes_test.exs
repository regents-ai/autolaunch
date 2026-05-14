defmodule AutolaunchWeb.ApiRoutesTest do
  use AutolaunchWeb.ConnCase, async: false

  alias AutolaunchWeb.Api.RegentStakingController
  alias AutolaunchWeb.Api.SubjectController

  @app_only_product_routes [
    {:get, "/regent/staking", RegentStakingController, :show},
    {:get, "/regent/staking/account/:address", RegentStakingController, :account},
    {:post, "/regent/staking/stake", RegentStakingController, :stake},
    {:post, "/regent/staking/unstake", RegentStakingController, :unstake},
    {:post, "/regent/staking/claim-usdc", RegentStakingController, :claim_usdc},
    {:post, "/regent/staking/claim-regent", RegentStakingController, :claim_regent},
    {:post, "/regent/staking/claim-and-restake-regent", RegentStakingController,
     :claim_and_restake_regent},
    {:post, "/regent/staking/deposit-usdc/prepare", RegentStakingController, :prepare_deposit},
    {:post, "/regent/staking/withdraw-treasury/prepare", RegentStakingController,
     :prepare_withdraw_treasury}
  ]

  @human_browser_product_routes [
    {:post, "/agent-pairings"},
    {:get, "/agent-pairings/:id"},
    {:post, "/trust/x/start"},
    {:post, "/trust/x/callback"},
    {:get, "/me/profile"},
    {:post, "/me/profile/refresh"},
    {:get, "/me/holdings"},
    {:get, "/me/bids"}
  ]

  @agent_only_product_routes [
    {:get, "/subjects/:id/accounting-tags", SubjectController, :accounting_tags}
  ]

  @public_app_routes [
    {:post, "/agent-pairings/complete"},
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
      |> Enum.reject(&human_browser_product_route?/1)
      |> normalize_route_specs("/v1/app")

    agent_routes =
      "/v1/agent"
      |> product_route_specs()
      |> Enum.reject(&agent_only_product_route?/1)
      |> normalize_route_specs("/v1/agent")

    assert app_routes == agent_routes
  end

  test "agent-only accounting labels stay out of the browser session API" do
    app_routes = product_route_specs("/v1/app")
    agent_routes = product_route_specs("/v1/agent")

    for route <- @agent_only_product_routes do
      refute route in normalize_route_specs(app_routes, "/v1/app")
      assert route in normalize_route_specs(agent_routes, "/v1/agent")
    end
  end

  test "app-only Regent staking routes stay out of the agent API" do
    app_routes = product_route_specs("/v1/app")
    agent_routes = product_route_specs("/v1/agent")

    for route <- @app_only_product_routes do
      assert route in normalize_route_specs(app_routes, "/v1/app")
      refute route in normalize_route_specs(agent_routes, "/v1/agent")
    end
  end

  test "human browser routes stay out of the agent API" do
    app_routes = product_route_specs("/v1/app")
    agent_routes = product_route_specs("/v1/agent")

    for route <- @human_browser_product_routes do
      assert route in route_methods_and_paths(app_routes, "/v1/app")
      refute route in route_methods_and_paths(agent_routes, "/v1/agent")
    end
  end

  test "Phoenix API routes match the Autolaunch OpenAPI contract" do
    documented_routes =
      "docs/api-contract.openapiv3.yaml"
      |> openapi_routes()
      |> Enum.reject(&platform_regent_staking_route?/1)
      |> Enum.sort()

    phoenix_routes =
      AutolaunchWeb.Router.__routes__()
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.filter(fn {_verb, path} -> contract_checked_path?(path) end)
      |> Enum.reject(&platform_regent_staking_route?/1)
      |> Enum.sort()

    assert phoenix_routes == documented_routes
  end

  test "Autolaunch does not mount Platform-owned Regent staking agent routes" do
    phoenix_routes =
      AutolaunchWeb.Router.__routes__()
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.filter(&platform_regent_staking_route?/1)

    assert phoenix_routes == []
  end

  test "CLI path templates point at live Phoenix routes" do
    phoenix_paths =
      AutolaunchWeb.Router.__routes__()
      |> Enum.map(& &1.path)
      |> MapSet.new()

    cli_paths =
      "docs/cli-contract.yaml"
      |> yaml_path_templates()
      |> Enum.map(&openapi_path_to_phoenix/1)

    for path <- cli_paths do
      assert MapSet.member?(phoenix_paths, path),
             "#{path} is listed in cli-contract.yaml but is not routed"
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

  defp route_methods_and_paths(route_specs, prefix) do
    route_specs
    |> Enum.map(fn {verb, path, _plug, _plug_opts} ->
      {verb, String.replace_prefix(path, prefix, "")}
    end)
    |> Enum.sort()
  end

  defp public_app_route?({verb, path, _plug, _plug_opts}) do
    {verb, String.replace_prefix(path, "/v1/app", "")} in @public_app_routes
  end

  defp app_only_product_route?({verb, path, plug, plug_opts}) do
    {verb, String.replace_prefix(path, "/v1/app", ""), plug, plug_opts} in @app_only_product_routes
  end

  defp human_browser_product_route?({verb, path, _plug, _plug_opts}) do
    {verb, String.replace_prefix(path, "/v1/app", "")} in @human_browser_product_routes
  end

  defp agent_only_product_route?({verb, path, plug, plug_opts}) do
    {verb, String.replace_prefix(path, "/v1/agent", ""), plug, plug_opts} in @agent_only_product_routes
  end

  defp openapi_routes(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({MapSet.new(), nil}, fn line, {routes, current_path} ->
      cond do
        Regex.match?(~r/^  \//, line) ->
          [_, path] = Regex.run(~r/^  ([^:]+):/, line)

          phoenix_path = openapi_path_to_phoenix(path)

          if contract_checked_path?(phoenix_path) do
            {routes, phoenix_path}
          else
            {routes, nil}
          end

        current_path && Regex.match?(~r/^    (get|post|patch|delete):/, line) ->
          [_, method] = Regex.run(~r/^    (get|post|patch|delete):/, line)
          {MapSet.put(routes, {String.to_atom(method), current_path}), current_path}

        true ->
          {routes, current_path}
      end
    end)
    |> elem(0)
    |> MapSet.to_list()
  end

  defp yaml_path_templates(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^\s+- (\/v1\/(?:agent|app)\/.+)$/, line) do
        [_, path] -> [path | acc]
        _ -> acc
      end
    end)
    |> Enum.uniq()
  end

  defp openapi_path_to_phoenix(path) do
    String.replace(path, ~r/\{([^}]+)\}/, ":\\1")
  end

  defp platform_regent_staking_route?({_verb, path}), do: platform_regent_staking_path?(path)
  defp platform_regent_staking_route?(path), do: platform_regent_staking_path?(path)

  defp platform_regent_staking_path?(path) do
    String.starts_with?(path, "/v1/agent/regent/staking")
  end

  defp contract_checked_path?(path) do
    path == "/health" or path == "/prelaunch-assets/:file" or
      String.starts_with?(path, "/api/internal/") or
      String.starts_with?(path, "/v1/auth/") or
      String.starts_with?(path, "/v1/app/") or
      String.starts_with?(path, "/v1/agent/")
  end
end
