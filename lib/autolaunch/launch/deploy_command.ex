defmodule Autolaunch.Launch.DeployCommand do
  @moduledoc false

  alias Autolaunch.BaseChain
  alias Autolaunch.Launch.Job

  @uint40_max 1_099_511_627_775
  @convex_min_auction_duration_blocks 13

  def build(%Job{} = job, config) when is_list(config) do
    rpc_url = config_value_for_chain(job.chain_id, :rpc_url, config)

    cond do
      blank?(rpc_url) ->
        {:error, "Missing deploy RPC URL for #{job.network}.", empty_logs()}

      error = env_error(job.chain_id, config) ->
        {:error, error, empty_logs()}

      true ->
        args =
          ["script", deploy_script_target(config), "--rpc-url", rpc_url] ++
            credentials_args(config) ++ broadcast_args(job)

        {:ok,
         %{
           binary: deploy_binary(config),
           args: args,
           opts: [
             cd: deploy_workdir(config),
             env: command_env(job, config),
             stderr_to_stdout: true
           ]
         }}
    end
  end

  def deploy_binary(config), do: Keyword.get(config, :deploy_binary, "forge")
  def deploy_workdir(config), do: Keyword.get(config, :deploy_workdir, "")
  def deploy_script_target(config), do: Keyword.get(config, :deploy_script_target, "")

  def deploy_rpc_host(chain_id, config) do
    case config_value_for_chain(chain_id, :rpc_url, config) do
      nil ->
        nil

      "" ->
        nil

      url ->
        case URI.parse(url) do
          %URI{host: host} when is_binary(host) -> host
          _ -> "custom"
        end
    end
  end

  def command_env(%Job{} = job, config) do
    [
      {"AUTOLAUNCH_OWNER_ADDRESS", job.owner_address},
      {"AUTOLAUNCH_AGENT_ID", identity_agent_id(job, config)},
      {"AUTOLAUNCH_AGENT_NAME", job.agent_name || ""},
      {"AUTOLAUNCH_TOKEN_NAME", job.token_name || ""},
      {"AUTOLAUNCH_TOKEN_SYMBOL", job.token_symbol || ""},
      {"AUTOLAUNCH_TOKEN_METADATA_DESCRIPTION",
       Keyword.get(config, :token_metadata_description, "")},
      {"AUTOLAUNCH_TOKEN_METADATA_WEBSITE", Keyword.get(config, :token_metadata_website, "")},
      {"AUTOLAUNCH_TOKEN_METADATA_IMAGE", Keyword.get(config, :token_metadata_image, "")},
      {"CCA_REQUIRED_CURRENCY_RAISED", job.minimum_raise_usdc_raw || "0"},
      {"AUTOLAUNCH_TOTAL_SUPPLY", job.total_supply},
      {"AUTOLAUNCH_AGENT_SAFE_ADDRESS", job.agent_safe_address || ""},
      {"AUTOLAUNCH_LIFECYCLE_RUN_ID", job.lifecycle_run_id || ""},
      {"AUTOLAUNCH_LAUNCH_NOTES", job.launch_notes || ""},
      {"AUTOLAUNCH_NETWORK", job.network},
      {"AUTOLAUNCH_CHAIN_ID", Integer.to_string(job.chain_id)},
      {"AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS",
       Keyword.get(config, :revenue_share_factory_address, "")},
      {"AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS",
       Keyword.get(config, :revenue_ingress_factory_address, "")},
      {"AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS",
       Keyword.get(config, :lbp_strategy_factory_address, "")},
      {"AUTOLAUNCH_TOKEN_FACTORY_ADDRESS", Keyword.get(config, :token_factory_address, "")},
      {"REGENT_MULTISIG_ADDRESS", regent_multisig_address(config)},
      {"AUTOLAUNCH_FACTORY_OWNER_ADDRESS", Keyword.get(config, :factory_owner_address, "")},
      {"STRATEGY_OPERATOR", Keyword.get(config, :strategy_operator, "")},
      {"OFFICIAL_POOL_FEE", config_text(config, :official_pool_fee)},
      {"OFFICIAL_POOL_TICK_SPACING", config_text(config, :official_pool_tick_spacing)},
      {"CCA_TICK_SPACING_Q96", config_text(config, :cca_tick_spacing_q96)},
      {"CCA_FLOOR_PRICE_Q96", config_text(config, :cca_floor_price_q96)},
      {"AUCTION_DURATION_BLOCKS", config_text(config, :auction_duration_blocks)},
      {"CCA_PREBID_BLOCKS", config_text(config, :cca_prebid_blocks)},
      {"CCA_FINAL_BLOCK_BPS", config_text(config, :cca_final_block_bps)},
      {"CCA_START_BLOCK_OFFSET", config_text(config, :cca_start_block_offset)},
      {"CCA_CLAIM_BLOCK_OFFSET", config_text(config, :cca_claim_block_offset)},
      {"LBP_MIGRATION_BLOCK_OFFSET", config_text(config, :lbp_migration_block_offset)},
      {"LBP_SWEEP_BLOCK_OFFSET", config_text(config, :lbp_sweep_block_offset)},
      {"AUTOLAUNCH_USDC_ADDRESS", deploy_usdc_address(job.chain_id)},
      {"AUTOLAUNCH_CCA_FACTORY_ADDRESS",
       config_value_for_chain(job.chain_id, :cca_factory_address, config)},
      {"AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER",
       config_value_for_chain(job.chain_id, :pool_manager_address, config)},
      {"AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER",
       config_value_for_chain(job.chain_id, :position_manager_address, config)},
      {"AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS", identity_registry_address(config)}
    ]
    |> maybe_append_optional_env(
      "CCA_VALIDATION_HOOK",
      Keyword.get(config, :cca_validation_hook, "")
    )
  end

  def config_value_for_chain(chain_id, key, config) do
    active_chain_id = BaseChain.normalize_chain_id(Keyword.get(config, :chain_id, 84_532))

    if chain_id == active_chain_id and BaseChain.supported_chain_id?(chain_id) do
      Keyword.get(config, key, "")
    else
      ""
    end
  end

  defp env_error(chain_id, config) do
    cond do
      not BaseChain.supported_chain_id?(chain_id) ->
        "Unsupported deploy network."

      blank?(deploy_script_target(config)) ->
        "Missing launch deploy script target."

      blank?(deploy_workdir(config)) ->
        "Missing launch deploy workdir."

      blank?(Keyword.get(config, :revenue_share_factory_address, "")) ->
        "Missing revenue share factory address."

      blank?(Keyword.get(config, :revenue_ingress_factory_address, "")) ->
        "Missing revenue ingress factory address."

      blank?(Keyword.get(config, :lbp_strategy_factory_address, "")) ->
        "Missing Regent LBP strategy factory address."

      blank?(Keyword.get(config, :token_factory_address, "")) ->
        "Missing token factory address."

      not valid_address?(Keyword.get(config, :factory_owner_address, "")) ->
        "Missing factory owner address."

      not valid_address?(Keyword.get(config, :strategy_operator, "")) ->
        "Missing strategy operator address."

      not valid_integer?(Keyword.get(config, :official_pool_fee, ""), 0) ->
        "Missing official pool fee."

      not valid_integer?(Keyword.get(config, :official_pool_tick_spacing, ""), 1) ->
        "Missing official pool tick spacing."

      not valid_integer?(Keyword.get(config, :cca_tick_spacing_q96, ""), 1) ->
        "Missing CCA tick spacing."

      not valid_integer?(Keyword.get(config, :cca_floor_price_q96, ""), 1) ->
        "Missing CCA floor price."

      not valid_integer?(
        Keyword.get(config, :auction_duration_blocks, ""),
        @convex_min_auction_duration_blocks,
        @uint40_max
      ) ->
        "Invalid auction duration."

      not valid_integer?(Keyword.get(config, :cca_prebid_blocks, ""), 0, @uint40_max) ->
        "Invalid CCA prebid blocks."

      not valid_integer?(Keyword.get(config, :cca_final_block_bps, ""), 2_000, 4_000) ->
        "Missing CCA final block basis points."

      not valid_integer?(Keyword.get(config, :cca_start_block_offset, ""), 0) ->
        "Missing CCA start block offset."

      blank?(config_value_for_chain(chain_id, :pool_manager_address, config)) ->
        "Missing #{BaseChain.network_label(chain_id)} Uniswap v4 pool manager address."

      blank?(config_value_for_chain(chain_id, :cca_factory_address, config)) ->
        "Missing #{BaseChain.network_label(chain_id)} CCA factory address."

      true ->
        nil
    end
  end

  defp credentials_args(config) do
    account = Keyword.get(config, :deploy_account, "")
    sender = Keyword.get(config, :deploy_sender, "")
    password = Keyword.get(config, :deploy_password, "")

    []
    |> append_arg("--account", account)
    |> append_arg("--sender", sender)
    |> append_password(account, password)
  end

  defp append_arg(args, _flag, ""), do: args
  defp append_arg(args, flag, value), do: args ++ [flag, value]

  defp append_password(args, "", _password), do: args
  defp append_password(args, _account, ""), do: args
  defp append_password(args, _account, password), do: args ++ ["--password", password]

  defp broadcast_args(%Job{broadcast: true}), do: ["--broadcast"]
  defp broadcast_args(_job), do: []

  defp deploy_usdc_address(chain_id) do
    case BaseChain.canonical_usdc_address(chain_id) do
      {:ok, address} -> address
      {:error, _reason} -> ""
    end
  end

  defp regent_multisig_address(config) do
    Keyword.get(
      config,
      :regent_multisig_address,
      "0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e"
    )
  end

  defp identity_registry_address(config) do
    address = Keyword.get(config, :identity_registry_address, "")

    if valid_address?(address), do: address, else: ""
  end

  defp identity_agent_id(%Job{} = job, config) do
    if identity_registry_address(config) == "", do: "", else: job.agent_id || ""
  end

  defp maybe_append_optional_env(env, vars, value) do
    if blank?(value), do: env, else: env ++ [{vars, value}]
  end

  defp config_text(config, key) do
    case Keyword.get(config, key, "") do
      nil -> ""
      value -> to_string(value)
    end
  end

  defp valid_address?(value) when is_binary(value),
    do: Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, value)

  defp valid_address?(_value), do: false

  defp valid_integer?(value, min) when is_integer(value), do: value >= min

  defp valid_integer?(value, min) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer >= min
      _ -> false
    end
  end

  defp valid_integer?(_value, _min), do: false

  defp valid_integer?(value, min, max) when is_integer(value), do: value >= min and value <= max

  defp valid_integer?(value, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer >= min and integer <= max
      _ -> false
    end
  end

  defp valid_integer?(_value, _min, _max), do: false

  defp empty_logs, do: %{stdout_tail: "", stderr_tail: ""}
  defp blank?(value), do: value in [nil, ""]
end
