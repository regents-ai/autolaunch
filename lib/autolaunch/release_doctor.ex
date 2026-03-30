defmodule Autolaunch.ReleaseDoctor do
  @moduledoc false

  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Repo

  @sepolia_chain_id 11_155_111
  @launch_address_checks [
    {:eth_sepolia_factory_address, "Sepolia CCA factory address"},
    {:eth_sepolia_pool_manager_address, "Sepolia Uniswap v4 pool manager address"},
    {:eth_sepolia_position_manager_address, "Sepolia Uniswap v4 position manager address"},
    {:eth_sepolia_usdc_address, "Sepolia USDC address"},
    {:revenue_share_factory_address, "revenue share factory address"},
    {:revenue_ingress_factory_address, "revenue ingress factory address"},
    {:lbp_strategy_factory_address, "Regent LBP strategy factory address"},
    {:token_factory_address, "token factory address"}
  ]
  @trust_networks [
    {"world", "World AgentBook config"},
    {"base", "Base AgentBook config"},
    {"base-sepolia", "Base Sepolia AgentBook config"}
  ]

  def run do
    checks =
      [
        repo_check(),
        privy_config_check(),
        siwa_config_check(),
        siwa_reachability_check(),
        deploy_binary_check(),
        deploy_workdir_check(),
        deploy_script_target_check(),
        sepolia_rpc_check()
      ] ++ launch_address_checks() ++ trust_checks()

    %{
      ok: Enum.all?(checks, &blocking_check_ok?/1),
      checks: checks
    }
  end

  defp repo_check do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} ->
        ok_check("repo_connectivity", :error, "Database connection succeeded.")

      {:error, reason} ->
        fail_check("repo_connectivity", :error, "Database connection failed: #{inspect(reason)}")
    end
  end

  defp privy_config_check do
    privy = Application.get_env(:autolaunch, :privy, [])

    if present?(Keyword.get(privy, :app_id)) and present?(Keyword.get(privy, :verification_key)) do
      ok_check("privy_config", :error, "Privy app id and verification key are configured.")
    else
      fail_check("privy_config", :error, "Privy app id or verification key is missing.")
    end
  end

  defp siwa_config_check do
    siwa = Application.get_env(:autolaunch, :siwa, [])

    if present?(Keyword.get(siwa, :internal_url)) and present?(Keyword.get(siwa, :shared_secret)) do
      ok_check("siwa_config", :error, "SIWA internal url and shared secret are configured.")
    else
      fail_check("siwa_config", :error, "SIWA internal url or shared secret is missing.")
    end
  end

  defp siwa_reachability_check do
    siwa = Application.get_env(:autolaunch, :siwa, [])

    case Keyword.get(siwa, :internal_url) do
      url when is_binary(url) and url != "" ->
        case http_client().get(
               url: url,
               receive_timeout: 2_000,
               connect_options: [timeout: 2_000]
             ) do
          {:ok, %{status: status}} ->
            ok_check("siwa_reachability", :error, "SIWA host responded with HTTP #{status}.")

          {:error, reason} ->
            fail_check(
              "siwa_reachability",
              :error,
              "SIWA host is unreachable: #{inspect(reason)}"
            )
        end

      _ ->
        fail_check("siwa_reachability", :error, "SIWA internal url is missing.")
    end
  end

  defp deploy_binary_check do
    launch = Application.get_env(:autolaunch, :launch, [])
    binary = Keyword.get(launch, :deploy_binary, "")

    cond do
      not present?(binary) ->
        fail_check("deploy_binary", :error, "Launch deploy binary is missing.")

      binary_executable?(binary) ->
        ok_check("deploy_binary", :error, "Launch deploy binary is executable.")

      true ->
        fail_check("deploy_binary", :error, "Launch deploy binary is not executable: #{binary}")
    end
  end

  defp deploy_workdir_check do
    launch = Application.get_env(:autolaunch, :launch, [])
    workdir = Keyword.get(launch, :deploy_workdir, "")

    cond do
      not present?(workdir) ->
        fail_check("deploy_workdir", :error, "Launch deploy workdir is missing.")

      File.dir?(workdir) ->
        ok_check("deploy_workdir", :error, "Launch deploy workdir exists.")

      true ->
        fail_check("deploy_workdir", :error, "Launch deploy workdir does not exist: #{workdir}")
    end
  end

  defp deploy_script_target_check do
    launch = Application.get_env(:autolaunch, :launch, [])

    if present?(Keyword.get(launch, :deploy_script_target)) do
      ok_check("deploy_script_target", :error, "Launch deploy script target is configured.")
    else
      fail_check("deploy_script_target", :error, "Launch deploy script target is missing.")
    end
  end

  defp sepolia_rpc_check do
    case Rpc.block_number(@sepolia_chain_id) do
      {:ok, block_number} when is_integer(block_number) and block_number > 0 ->
        ok_check("sepolia_rpc", :error, "Sepolia RPC returned block #{block_number}.")

      {:error, reason} ->
        fail_check("sepolia_rpc", :error, "Sepolia RPC failed: #{inspect(reason)}")

      other ->
        fail_check(
          "sepolia_rpc",
          :error,
          "Sepolia RPC returned an invalid response: #{inspect(other)}"
        )
    end
  end

  defp launch_address_checks do
    launch = Application.get_env(:autolaunch, :launch, [])

    Enum.map(@launch_address_checks, fn {key, label} ->
      if configured_address?(Keyword.get(launch, key)) do
        ok_check("launch_#{key}", :error, "#{label} is configured.")
      else
        fail_check("launch_#{key}", :error, "#{label} is missing or invalid.")
      end
    end)
  end

  defp trust_checks do
    networks = Application.get_env(:agent_world, :networks, %{})

    Enum.map(@trust_networks, fn {network_key, label} ->
      config = Map.get(networks, network_key, %{})

      if present?(Map.get(config, :rpc_url)) and
           configured_address?(Map.get(config, :contract_address)) do
        ok_check("trust_#{network_key}", :warning, "#{label} is configured.")
      else
        fail_check(
          "trust_#{network_key}",
          :warning,
          "#{label} is incomplete. Trust follow-up will stay unavailable until it is configured."
        )
      end
    end)
  end

  defp blocking_check_ok?(%{severity: :warning}), do: true
  defp blocking_check_ok?(%{ok: ok}), do: ok

  defp configured_address?(value) when is_binary(value) do
    Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, String.trim(value))
  end

  defp configured_address?(_value), do: false

  defp http_client do
    Application.get_env(:autolaunch, :release_doctor_http_client, Req)
  end

  defp binary_executable?(binary) when is_binary(binary) do
    cond do
      binary == "" ->
        false

      Path.type(binary) == :absolute or String.contains?(binary, "/") ->
        File.exists?(binary)

      true ->
        not is_nil(System.find_executable(binary))
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp ok_check(key, severity, detail),
    do: %{key: key, ok: true, severity: severity, detail: detail}

  defp fail_check(key, severity, detail),
    do: %{key: key, ok: false, severity: severity, detail: detail}
end
