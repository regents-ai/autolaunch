defmodule Autolaunch.ReleaseDoctor do
  @moduledoc false
  import Bitwise

  alias Autolaunch.BaseChain
  alias Autolaunch.Contracts.Abi
  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Prelaunch.AssetStorage
  alias Autolaunch.Repo

  @launch_address_checks [
    {:cca_factory_address, "CCA factory address"},
    {:pool_manager_address, "Uniswap v4 pool manager address"},
    {:position_manager_address, "Uniswap v4 position manager address"},
    {:auction_quote_token_address, "auction quote token address"},
    {:revenue_usdc_address, "revenue USDC address"},
    {:revenue_share_factory_address, "revenue share factory address"},
    {:revenue_ingress_factory_address, "revenue ingress factory address"},
    {:lbp_strategy_factory_address, "Regent LBP strategy factory address"},
    {:token_factory_address, "UERC20 token factory address"}
  ]
  @verifier_chain_address_checks [
    {:pool_manager_addresses, "Uniswap v4 pool manager address"},
    {:auction_quote_token_addresses, "auction quote token address"},
    {:revenue_usdc_addresses, "revenue USDC address"},
    {:revenue_share_factory_addresses, "revenue share factory address"},
    {:revenue_ingress_factory_addresses, "revenue ingress factory address"},
    {:chain_rpc_urls, "RPC url"}
  ]
  @identity_warning_checks [
    {:identity_registry_address, "identity registry address"}
  ]
  @verifier_identity_warning_checks [
    {:erc8004_subgraph_urls, "ERC-8004 subgraph url"},
    {:identity_registry_addresses, "identity registry address"}
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
        shared_launch_table_check(),
        prelaunch_upload_storage_check(),
        launch_rpc_check()
      ] ++
        launch_address_checks() ++
        launch_contract_code_checks() ++
        launch_token_checks() ++
        launch_identity_warning_checks() ++
        launch_script_input_checks() ++
        verifier_chain_address_checks() ++ verifier_identity_warning_checks() ++ trust_checks()

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

    if present?(Keyword.get(siwa, :internal_url)) do
      ok_check("siwa_config", :error, "SIWA broker url is configured.")
    else
      fail_check("siwa_config", :error, "SIWA broker url is missing.")
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
    binary = InfrastructureConfig.launch_value(:deploy_binary) || ""

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
    workdir = InfrastructureConfig.launch_value(:deploy_workdir) || ""

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
    if present?(InfrastructureConfig.launch_value(:deploy_script_target)) do
      ok_check("deploy_script_target", :error, "Launch deploy script target is configured.")
    else
      fail_check("deploy_script_target", :error, "Launch deploy script target is missing.")
    end
  end

  defp shared_launch_table_check do
    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'agent_token_launches')",
           []
         ) do
      {:ok, %{rows: [[true]]}} ->
        ok_check("shared_launch_table", :error, "Launch record table is present.")

      _ ->
        fail_check("shared_launch_table", :error, "Launch record table is missing.")
    end
  end

  defp prelaunch_upload_storage_check do
    if AssetStorage.writable?() do
      ok_check("prelaunch_upload_storage", :error, "Prelaunch upload storage is writable.")
    else
      fail_check(
        "prelaunch_upload_storage",
        :error,
        "Prelaunch upload storage is missing or not writable."
      )
    end
  end

  defp launch_rpc_check do
    chain_id = launch_chain_id()
    chain_label = launch_chain_label(chain_id)

    case Rpc.block_number(chain_id) do
      {:ok, block_number} when is_integer(block_number) and block_number > 0 ->
        ok_check("launch_rpc", :error, "#{chain_label} RPC returned block #{block_number}.")

      {:error, reason} ->
        fail_check("launch_rpc", :error, "#{chain_label} RPC failed: #{inspect(reason)}")

      other ->
        fail_check(
          "launch_rpc",
          :error,
          "#{chain_label} RPC returned an invalid response: #{inspect(other)}"
        )
    end
  end

  defp launch_address_checks do
    Enum.map(@launch_address_checks, fn {key, label} ->
      if InfrastructureConfig.configured_address?(InfrastructureConfig.launch_value(key)) do
        ok_check("launch_#{key}", :error, "#{label} is configured.")
      else
        fail_check("launch_#{key}", :error, "#{label} is missing or invalid.")
      end
    end)
  end

  defp launch_contract_code_checks do
    chain_id = launch_chain_id()

    [
      {:cca_factory_address, "CCA factory"},
      {:pool_manager_address, "Uniswap v4 pool manager"},
      {:position_manager_address, "Uniswap v4 position manager"},
      {:revenue_share_factory_address, "revenue share factory"},
      {:revenue_ingress_factory_address, "revenue ingress factory"},
      {:lbp_strategy_factory_address, "Regent LBP strategy factory"},
      {:token_factory_address, "UERC20 token factory"}
    ]
    |> Enum.map(fn {key, label} ->
      address = InfrastructureConfig.launch_value(key)
      contract_code_check(chain_id, key, label, address)
    end)
  end

  defp launch_token_checks do
    chain_id = launch_chain_id()
    auction_quote_token = InfrastructureConfig.launch_text(:auction_quote_token_address)
    revenue_usdc = InfrastructureConfig.launch_text(:revenue_usdc_address)

    [
      canonical_token_check(
        "launch_auction_quote_token_canonical",
        auction_quote_token,
        BaseChain.canonical_regent_address!(chain_id),
        "Auction quote token"
      ),
      canonical_token_check(
        "launch_revenue_usdc_token_canonical",
        revenue_usdc,
        BaseChain.canonical_usdc_address!(chain_id),
        "Revenue token"
      ),
      token_contract_check(
        "launch_auction_quote_token_contract",
        chain_id,
        auction_quote_token,
        "$REGENT auction quote token",
        18
      ),
      token_contract_check(
        "launch_revenue_usdc_token_contract",
        chain_id,
        revenue_usdc,
        "Base USDC revenue token",
        6
      )
    ]
  end

  defp canonical_token_check(key, configured, expected, label) do
    if normalize_address(configured) == normalize_address(expected) do
      ok_check(key, :error, "#{label} is configured to #{expected}.")
    else
      fail_check(key, :error, "#{label} is #{configured || "missing"}, expected #{expected}.")
    end
  end

  defp token_contract_check(key, chain_id, address, label, expected_decimals) do
    cond do
      not configured_address?(address) ->
        fail_check(key, :error, "#{label} address is missing or invalid.")

      true ->
        code = Rpc.code_at(chain_id, address)
        decimals = safe_uint_call(chain_id, address, :decimals)

        cond do
          has_contract_code?(code) and decimals == expected_decimals ->
            ok_check(
              key,
              :error,
              "#{label} has contract code and reports #{expected_decimals} decimals."
            )

          code == {:ok, "0x"} or code == {:ok, "0X"} ->
            fail_check(key, :error, "#{label} address has no contract code.")

          decimals != expected_decimals ->
            fail_check(
              key,
              :error,
              "#{label} reports #{decimals || "unreadable"} decimals, expected #{expected_decimals}."
            )

          true ->
            fail_check(key, :error, "#{label} contract code could not be read.")
        end
    end
  end

  defp launch_identity_warning_checks do
    chain_id = launch_chain_id()

    Enum.map(@identity_warning_checks, fn {key, label} ->
      address = InfrastructureConfig.launch_value(key)
      contract_code_check(chain_id, key, label, address, :warning)
    end)
  end

  defp contract_code_check(chain_id, key, label, address, severity \\ :error) do
    cond do
      not configured_address?(address) ->
        fail_check("launch_code_#{key}", severity, "#{label} address is missing or invalid.")

      true ->
        case Rpc.code_at(chain_id, address) do
          {:ok, code} when is_binary(code) and code not in ["0x", "0X"] ->
            ok_check("launch_code_#{key}", severity, "#{label} has contract code.")

          {:ok, _empty} ->
            fail_check("launch_code_#{key}", severity, "#{label} has no contract code.")

          {:error, reason} ->
            fail_check(
              "launch_code_#{key}",
              severity,
              "#{label} code check failed: #{inspect(reason)}"
            )

          other ->
            fail_check(
              "launch_code_#{key}",
              severity,
              "#{label} code check returned #{inspect(other)}"
            )
        end
    end
  end

  defp launch_script_input_checks do
    Enum.map(InfrastructureConfig.launch_script_inputs(), fn {key, env_name, rule} ->
      if InfrastructureConfig.valid_script_input?(key, rule) do
        ok_check("launch_script_#{key}", :error, "#{env_name} is configured.")
      else
        fail_check("launch_script_#{key}", :error, "#{env_name} is missing or invalid.")
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

  defp verifier_chain_address_checks do
    active_chain_id = launch_chain_id()

    for %{id: chain_id, label: chain_label} <- InfrastructureConfig.base_chains(),
        {key, label} <- @verifier_chain_address_checks do
      value = InfrastructureConfig.chain_text(key, chain_id)
      severity = verifier_chain_severity(chain_id, active_chain_id)

      if configured_verifier_value?(key, value) do
        ok_check("launch_#{key}_#{chain_id}", severity, "#{chain_label} #{label} is configured.")
      else
        fail_check(
          "launch_#{key}_#{chain_id}",
          severity,
          "#{chain_label} #{label} is missing or invalid."
        )
      end
    end
  end

  defp verifier_chain_severity(chain_id, chain_id), do: :error
  defp verifier_chain_severity(_chain_id, _active_chain_id), do: :warning

  defp verifier_identity_warning_checks do
    for %{id: chain_id, label: chain_label} <- InfrastructureConfig.base_chains(),
        {key, label} <- @verifier_identity_warning_checks do
      value = InfrastructureConfig.chain_text(key, chain_id)

      if configured_warning_value?(key, value) do
        ok_check("launch_#{key}_#{chain_id}", :warning, "#{chain_label} #{label} is configured.")
      else
        fail_check(
          "launch_#{key}_#{chain_id}",
          :warning,
          "#{chain_label} #{label} is missing or invalid. Trust follow-up will stay unavailable until it is configured."
        )
      end
    end
  end

  defp configured_warning_value?(:erc8004_subgraph_urls, value), do: configured_url?(value)
  defp configured_warning_value?(_key, value), do: configured_address?(value)

  defp blocking_check_ok?(%{severity: :warning}), do: true
  defp blocking_check_ok?(%{ok: ok}), do: ok

  defp configured_address?(value) when is_binary(value) do
    Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, String.trim(value))
  end

  defp configured_address?(_value), do: false

  defp normalize_address(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_address(_value), do: nil

  defp has_contract_code?({:ok, code}) when is_binary(code), do: code not in ["0x", "0X"]
  defp has_contract_code?(_result), do: false

  defp safe_uint_call(chain_id, to, selector_name) do
    case Rpc.eth_call(chain_id, to, Abi.encode_call(selector_name)) do
      {:ok, data} -> Abi.decode_uint256(data)
      _ -> nil
    end
  end

  defp configured_url?(value) when is_binary(value), do: String.trim(value) != ""
  defp configured_url?(_value), do: false

  defp configured_verifier_value?(key, value)
       when key in [:chain_rpc_urls],
       do: configured_url?(value)

  defp configured_verifier_value?(_key, value), do: configured_address?(value)

  defp http_client do
    Application.get_env(:autolaunch, :release_doctor_http_client, Req)
  end

  defp binary_executable?(binary) when is_binary(binary) do
    cond do
      binary == "" ->
        false

      Path.type(binary) == :absolute or String.contains?(binary, "/") ->
        path_executable?(binary)

      true ->
        not is_nil(System.find_executable(binary))
    end
  end

  defp path_executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _ -> false
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp launch_chain_id do
    InfrastructureConfig.launch_chain_id!()
  end

  defp launch_chain_label(84_532), do: "Base Sepolia"
  defp launch_chain_label(8_453), do: "Base"
  defp launch_chain_label(_chain_id), do: "Launch"

  defp ok_check(key, severity, detail),
    do: %{key: key, ok: true, severity: severity, detail: detail}

  defp fail_check(key, severity, detail),
    do: %{key: key, ok: false, severity: severity, detail: detail}
end
