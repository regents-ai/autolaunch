defmodule AutolaunchWeb.ApiRoutesTest do
  use AutolaunchWeb.ConnCase, async: false

  alias AutolaunchWeb.Api.RegentStakingController

  @app_only_product_routes [
    {:post, "/regent/staking/deposit-usdc/prepare", RegentStakingController, :prepare_deposit},
    {:post, "/regent/staking/withdraw-treasury/prepare", RegentStakingController,
     :prepare_withdraw_treasury}
  ]

  @human_browser_product_routes [
    {:post, "/trust/x/start"},
    {:post, "/trust/x/callback"},
    {:get, "/me/profile"},
    {:post, "/me/profile/refresh"},
    {:get, "/me/holdings"},
    {:get, "/me/bids"}
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
      |> Enum.reject(&human_browser_product_route?/1)
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
      |> Enum.reject(&shared_regent_staking_route?/1)
      |> Enum.sort()

    phoenix_routes =
      AutolaunchWeb.Router.__routes__()
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.filter(fn {_verb, path} ->
        String.starts_with?(path, "/v1/app/") or String.starts_with?(path, "/v1/agent/")
      end)
      |> Enum.reject(&shared_regent_staking_route?/1)
      |> Enum.sort()

    assert phoenix_routes == documented_routes
  end

  test "Autolaunch mirrors the shared Regent staking agent contract" do
    documented_routes =
      "../regents-cli/docs/regent-services-contract.openapiv3.yaml"
      |> openapi_routes()
      |> Enum.filter(&shared_regent_staking_route?/1)
      |> Enum.sort()

    phoenix_routes =
      AutolaunchWeb.Router.__routes__()
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.filter(&shared_regent_staking_route?/1)
      |> Enum.filter(fn {_verb, path} -> String.starts_with?(path, "/v1/agent/") end)
      |> Enum.sort()

    assert phoenix_routes == documented_routes
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

  defp openapi_routes(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({MapSet.new(), nil}, fn line, {routes, current_path} ->
      cond do
        Regex.match?(~r/^  \/v1\/(app|agent)\//, line) ->
          [_, path] = Regex.run(~r/^  ([^:]+):/, line)
          {routes, openapi_path_to_phoenix(path)}

        current_path && Regex.match?(~r/^    (get|post|patch|delete):/, line) ->
          [_, method] = Regex.run(~r/^    (get|post|patch|delete):/, line)
          {MapSet.put(routes, {String.to_atom(method), current_path}), current_path}

        Regex.match?(~r/^  \//, line) ->
          {routes, nil}

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
      case Regex.run(~r/^\s+- (\/v1\/agent\/.+)$/, line) do
        [_, path] -> [path | acc]
        _ -> acc
      end
    end)
    |> Enum.uniq()
  end

  defp openapi_path_to_phoenix(path) do
    String.replace(path, ~r/\{([^}]+)\}/, ":\\1")
  end

  defp shared_regent_staking_route?({_verb, path}), do: shared_regent_staking_path?(path)
  defp shared_regent_staking_route?(path), do: shared_regent_staking_path?(path)

  defp shared_regent_staking_path?(path) do
    String.starts_with?(path, "/v1/agent/regent/staking")
  end
end
