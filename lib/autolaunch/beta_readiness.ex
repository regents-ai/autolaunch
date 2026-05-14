defmodule Autolaunch.BetaReadiness do
  @moduledoc false

  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.Launch
  alias Autolaunch.Prelaunch.AssetStorage
  alias Autolaunch.RegentStaking
  alias Autolaunch.Repo

  @launch_address_env_names %{
    cca_factory_address: "AUTOLAUNCH_CCA_FACTORY_ADDRESS",
    pool_manager_address: "AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER",
    position_manager_address: "AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER",
    usdc_address: "canonical Base USDC",
    revenue_share_factory_address: "AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS",
    revenue_ingress_factory_address: "AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS",
    lbp_strategy_factory_address: "AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS",
    token_factory_address: "AUTOLAUNCH_TOKEN_FACTORY_ADDRESS (UERC20 factory)"
  }
  @expected_routes [
    {:get, "/"},
    {:get, "/health"},
    {:get, "/regent-staking"},
    {:get, "/tokens"},
    {:get, "/contracts"},
    {:get, "/v1/app/regent/staking"},
    {:post, "/v1/app/launch/preview"},
    {:get, "/v1/app/auctions"}
  ]

  def run do
    checks =
      [
        repo_check(),
        shared_launch_table_check(),
        launch_chain_check(),
        launch_rpc_check(),
        prelaunch_upload_storage_check()
      ] ++
        launch_address_checks() ++
        launch_script_input_checks() ++
        [
          regent_staking_config_check(),
          route_exposure_check(),
          launch_read_path_check(),
          regent_staking_read_path_check()
        ]

    %{
      ok: Enum.all?(checks, & &1.ok),
      checks: checks
    }
  end

  defp repo_check do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} -> ok("database", "Database connection works.")
      {:error, reason} -> fail("database", "Database connection failed: #{inspect(reason)}")
    end
  end

  defp shared_launch_table_check do
    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'agent_token_launches')",
           []
         ) do
      {:ok, %{rows: [[true]]}} ->
        ok("shared_launch_table", "Launch record table is present.")

      _ ->
        fail("shared_launch_table", "Launch record table is missing.")
    end
  end

  defp launch_chain_check do
    case InfrastructureConfig.launch_chain_id() do
      {:ok, chain_id} ->
        ok("launch_chain", "Launch chain is Base: #{chain_id}.")

      {:error, _reason} ->
        fail("launch_chain", "Launch chain must be Base mainnet.")
    end
  end

  defp launch_rpc_check do
    case InfrastructureConfig.launch_rpc_url() do
      {:ok, _url} -> ok("launch_rpc", "AUTOLAUNCH_RPC_URL is configured.")
      {:error, _reason} -> fail("launch_rpc", "AUTOLAUNCH_RPC_URL is missing.")
    end
  end

  defp launch_address_checks do
    Enum.map(InfrastructureConfig.launch_address_keys(), fn key ->
      env_name = Map.fetch!(@launch_address_env_names, key)

      if InfrastructureConfig.configured_address?(InfrastructureConfig.launch_value(key)) do
        ok("launch_#{key}", "#{env_name} is configured.")
      else
        fail("launch_#{key}", "#{env_name} is missing or invalid.")
      end
    end)
  end

  defp launch_script_input_checks do
    Enum.map(InfrastructureConfig.launch_script_inputs(), fn {key, env_name, rule} ->
      if InfrastructureConfig.valid_script_input?(key, rule) do
        ok("launch_script_#{key}", "#{env_name} is configured.")
      else
        fail("launch_script_#{key}", "#{env_name} is missing or invalid.")
      end
    end)
  end

  defp prelaunch_upload_storage_check do
    if AssetStorage.writable?() do
      ok("prelaunch_upload_storage", "Prelaunch upload storage is writable.")
    else
      fail("prelaunch_upload_storage", "Prelaunch upload storage is missing or not writable.")
    end
  end

  defp regent_staking_config_check do
    with {:ok, _chain_id} <- InfrastructureConfig.regent_staking_chain_id(),
         {:ok, _rpc_url} <- InfrastructureConfig.regent_staking_rpc_url(),
         address when is_binary(address) <-
           InfrastructureConfig.regent_staking_address(:contract_address) do
      ok("regent_staking_config", "Regent staking configuration is present.")
    else
      {:error, :invalid_chain_id} ->
        fail(
          "regent_staking_config",
          "REGENT_STAKING_CHAIN_ID must be Base mainnet."
        )

      {:error, :missing_rpc_url} ->
        fail("regent_staking_config", "REGENT_STAKING_RPC_URL is missing.")

      _ ->
        fail("regent_staking_config", "REGENT_REVENUE_STAKING_ADDRESS is missing or invalid.")
    end
  end

  defp route_exposure_check do
    live_routes =
      AutolaunchWeb.Router.__routes__()
      |> MapSet.new(fn route -> {route.verb, route.path} end)

    missing = Enum.reject(@expected_routes, &MapSet.member?(live_routes, &1))

    case missing do
      [] -> ok("route_exposure", "Required public routes are present.")
      _ -> fail("route_exposure", "Missing required routes: #{format_routes(missing)}.")
    end
  end

  defp launch_read_path_check do
    case launch_module().list_auctions(%{"mode" => "all", "sort" => "newest"}, nil) do
      auctions when is_list(auctions) ->
        ok(
          "launch_read_path",
          "Autolaunch launch read path returned #{length(auctions)} auctions."
        )

      other ->
        fail("launch_read_path", "Autolaunch launch read path returned #{inspect(other)}.")
    end
  rescue
    error ->
      fail("launch_read_path", "Autolaunch launch read path failed: #{Exception.message(error)}")
  end

  defp regent_staking_read_path_check do
    case regent_staking_module().overview(nil) do
      {:ok, _state} ->
        ok("regent_staking_read_path", "Regent staking read path works.")

      {:error, reason} ->
        fail("regent_staking_read_path", "Regent staking read path failed: #{inspect(reason)}.")

      other ->
        fail("regent_staking_read_path", "Regent staking read path returned #{inspect(other)}.")
    end
  rescue
    error ->
      fail(
        "regent_staking_read_path",
        "Regent staking read path failed: #{Exception.message(error)}"
      )
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:beta_readiness, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp regent_staking_module do
    :autolaunch
    |> Application.get_env(:beta_readiness, [])
    |> Keyword.get(:regent_staking_module, RegentStaking)
  end

  defp format_routes(routes) do
    routes
    |> Enum.map(fn {method, path} ->
      "#{method |> Atom.to_string() |> String.upcase()} #{path}"
    end)
    |> Enum.join(", ")
  end

  defp ok(key, detail), do: %{key: key, ok: true, detail: detail}
  defp fail(key, detail), do: %{key: key, ok: false, detail: detail}
end
