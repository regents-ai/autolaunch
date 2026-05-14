defmodule Mix.Tasks.Autolaunch.ReleaseGate do
  @moduledoc false

  use Mix.Task

  @shortdoc "Runs Autolaunch release gates"
  @shared_services_contract "../regents-cli/docs/regent-services-contract.openapiv3.yaml"
  @platform_contract "../platform/api-contract.openapiv3.yaml"
  @path_dependencies [
    "../elixir-utils/cache",
    "../elixir-utils/xmtp",
    "../elixir-utils/ens",
    "../elixir-utils/world/agentbook",
    "../design-system/regent_ui"
  ]

  @impl true
  def run(_args) do
    Mix.shell().info("Checking Autolaunch release gates")

    check_contract_file!("docs/api-contract.openapiv3.yaml")
    check_contract_file!("docs/cli-contract.yaml")
    check_contract_file!(@shared_services_contract)
    check_contract_file!(@platform_contract)
    Enum.each(@path_dependencies, &check_path_dependency!/1)
    Mix.Task.run("autolaunch.release_packaging_check")
    run!("forge", ["build"], cd: "contracts")
    Mix.Task.run("autolaunch.generate_selectors", ["--check"])
    run!("mix", ["compile", "--warnings-as-errors"], cd: ".")
    check_api_contract_routes!()
    check_no_platform_regent_staking_agent_routes!()
    check_cli_contract_routes!()
    check_lifecycle_settlement_contract!()
    run!("mix", ["test"], cd: ".")
    run!("forge", ["test"], cd: "contracts")
    run!("npm", ["ci", "--include=dev"], cd: "assets")
    run!("npm", ["run", "typecheck"], cd: "assets")
    run!("npm", ["test"], cd: "assets")
  end

  defp check_contract_file!(path) do
    if File.exists?(path) do
      Mix.shell().info("Found #{path}")
    else
      Mix.raise("Missing release contract file: #{path}")
    end
  end

  defp check_path_dependency!(path) do
    if File.dir?(path) do
      Mix.shell().info("Found local path dependency #{path}")
    else
      Mix.raise("""
      Missing local path dependency: #{path}
      Check out the Regent sibling repositories before building, testing, or deploying Autolaunch.
      """)
    end
  end

  defp check_api_contract_routes! do
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

    if phoenix_routes == documented_routes do
      Mix.shell().info("Autolaunch API routes match docs/api-contract.openapiv3.yaml")
    else
      Mix.raise("""
      Autolaunch API routes do not match docs/api-contract.openapiv3.yaml.
      Update the YAML contract first, then update routes and tests to the same shape.
      """)
    end
  end

  defp check_cli_contract_routes! do
    phoenix_paths =
      AutolaunchWeb.Router.__routes__()
      |> Enum.map(& &1.path)
      |> MapSet.new()

    missing_paths =
      "docs/cli-contract.yaml"
      |> yaml_path_templates()
      |> Enum.map(&openapi_path_to_phoenix/1)
      |> Enum.reject(&MapSet.member?(phoenix_paths, &1))

    if missing_paths == [] do
      Mix.shell().info("Autolaunch CLI route templates match live Phoenix routes")
    else
      Mix.raise("""
      docs/cli-contract.yaml lists routes that Autolaunch does not serve:
      #{Enum.map_join(missing_paths, "\n", &"  - #{&1}")}
      """)
    end
  end

  defp check_lifecycle_settlement_contract! do
    api_contract = File.read!("docs/api-contract.openapiv3.yaml")

    required_values = [
      "awaiting_migration",
      "awaiting_auction_asset_return",
      "failed_auction_recoverable",
      "post_recovery_cleanup",
      "awaiting_sweeps",
      "ownership_acceptance_required",
      "settled",
      "wait",
      "migrate",
      "auction_sweep_currency",
      "auction_sweep_unsold_tokens",
      "recover_failed_auction",
      "accept_revenue_splitter_ownership",
      "accept_fee_registry_ownership",
      "accept_fee_vault_ownership",
      "accept_hook_ownership",
      "sweep_currency",
      "sweep_token",
      "release_vesting"
    ]

    missing_values = Enum.reject(required_values, &String.contains?(api_contract, &1))

    if missing_values == [] do
      Mix.shell().info("Autolaunch lifecycle settlement contract values are present")
    else
      Mix.raise("""
      docs/api-contract.openapiv3.yaml is missing lifecycle settlement values:
      #{Enum.map_join(missing_values, "\n", &"  - #{&1}")}
      """)
    end
  end

  defp check_no_platform_regent_staking_agent_routes! do
    phoenix_routes =
      AutolaunchWeb.Router.__routes__()
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.filter(&platform_regent_staking_route?/1)

    if phoenix_routes == [] do
      Mix.shell().info("Autolaunch does not mount Platform-owned Regent staking agent routes")
    else
      Mix.raise("""
      Autolaunch mounts Platform-owned Regent staking agent routes:
      #{Enum.map_join(phoenix_routes, "\n", fn {verb, path} -> "  - #{verb} #{path}" end)}
      """)
    end
  end

  defp run!(command, args, opts) do
    Mix.shell().info("Running #{Enum.join([command | args], " ")}")

    case System.cmd(command, args, Keyword.merge(opts, stderr_to_stdout: true)) do
      {output, 0} ->
        if String.trim(output) != "", do: Mix.shell().info(output)
        :ok

      {output, status} ->
        Mix.shell().error(output)
        Mix.raise("#{command} #{Enum.join(args, " ")} failed with status #{status}")
    end
  rescue
    error in ErlangError ->
      Mix.raise("Could not run #{command}: #{inspect(error.original)}")
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
