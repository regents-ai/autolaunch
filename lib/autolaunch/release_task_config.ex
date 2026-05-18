defmodule Autolaunch.ReleaseTaskConfig do
  @moduledoc false

  alias Autolaunch.BaseChain

  @text_envs [
    deploy_binary: "AUTOLAUNCH_DEPLOY_BINARY",
    deploy_workdir: "AUTOLAUNCH_DEPLOY_WORKDIR",
    deploy_script_target: "AUTOLAUNCH_DEPLOY_SCRIPT_TARGET",
    rpc_url: "AUTOLAUNCH_RPC_URL",
    cca_factory_address: "AUTOLAUNCH_CCA_FACTORY_ADDRESS",
    pool_manager_address: "AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER",
    position_manager_address: "AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER",
    auction_quote_token_address: "AUTOLAUNCH_AUCTION_QUOTE_TOKEN_ADDRESS",
    revenue_usdc_address: "AUTOLAUNCH_REVENUE_USDC_ADDRESS",
    revenue_share_factory_address: "AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS",
    revenue_ingress_factory_address: "AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS",
    lbp_strategy_factory_address: "AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS",
    token_factory_address: "AUTOLAUNCH_TOKEN_FACTORY_ADDRESS",
    erc8004_subgraph_url: "AUTOLAUNCH_ERC8004_SUBGRAPH_URL",
    identity_registry_address: "AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS",
    factory_owner_address: "AUTOLAUNCH_FACTORY_OWNER_ADDRESS",
    strategy_operator: "STRATEGY_OPERATOR",
    official_pool_fee: "OFFICIAL_POOL_FEE",
    official_pool_tick_spacing: "OFFICIAL_POOL_TICK_SPACING",
    cca_tick_spacing_q96: "CCA_TICK_SPACING_Q96",
    cca_floor_price_q96: "CCA_FLOOR_PRICE_Q96",
    cca_validation_hook: "CCA_VALIDATION_HOOK",
    auction_duration_blocks: "AUCTION_DURATION_BLOCKS",
    cca_prebid_blocks: "CCA_PREBID_BLOCKS",
    cca_final_block_bps: "CCA_FINAL_BLOCK_BPS",
    cca_start_block_offset: "CCA_START_BLOCK_OFFSET",
    cca_claim_block_offset: "CCA_CLAIM_BLOCK_OFFSET",
    lbp_migration_block_offset: "LBP_MIGRATION_BLOCK_OFFSET",
    lbp_sweep_block_offset: "LBP_SWEEP_BLOCK_OFFSET",
    regent_multisig_address: "REGENT_MULTISIG_ADDRESS"
  ]

  @map_envs [
    pool_manager_addresses: [
      {8_453, "AUTOLAUNCH_BASE_MAINNET_UNISWAP_V4_POOL_MANAGER"},
      {84_532, "AUTOLAUNCH_BASE_SEPOLIA_UNISWAP_V4_POOL_MANAGER"}
    ],
    revenue_share_factory_addresses: [
      {8_453, "AUTOLAUNCH_BASE_MAINNET_REVENUE_SHARE_FACTORY_ADDRESS"},
      {84_532, "AUTOLAUNCH_BASE_SEPOLIA_REVENUE_SHARE_FACTORY_ADDRESS"}
    ],
    revenue_ingress_factory_addresses: [
      {8_453, "AUTOLAUNCH_BASE_MAINNET_REVENUE_INGRESS_FACTORY_ADDRESS"},
      {84_532, "AUTOLAUNCH_BASE_SEPOLIA_REVENUE_INGRESS_FACTORY_ADDRESS"}
    ],
    lbp_strategy_factory_addresses: [
      {8_453, "AUTOLAUNCH_BASE_MAINNET_LBP_STRATEGY_FACTORY_ADDRESS"},
      {84_532, "AUTOLAUNCH_BASE_SEPOLIA_LBP_STRATEGY_FACTORY_ADDRESS"}
    ],
    erc8004_subgraph_urls: [
      {8_453, "AUTOLAUNCH_BASE_MAINNET_ERC8004_SUBGRAPH_URL"},
      {84_532, "AUTOLAUNCH_BASE_SEPOLIA_ERC8004_SUBGRAPH_URL"}
    ],
    identity_registry_addresses: [
      {8_453, "AUTOLAUNCH_BASE_MAINNET_IDENTITY_REGISTRY_ADDRESS"},
      {84_532, "AUTOLAUNCH_BASE_SEPOLIA_IDENTITY_REGISTRY_ADDRESS"}
    ]
  ]

  def apply! do
    :autolaunch
    |> Application.get_env(:launch, [])
    |> put_text_envs()
    |> put_numeric_env(:chain_id, "AUTOLAUNCH_CHAIN_ID")
    |> put_numeric_env(:deploy_timeout_ms, "AUTOLAUNCH_DEPLOY_TIMEOUT_MS")
    |> put_bool_env(:mock_deploy, "AUTOLAUNCH_MOCK_DEPLOY")
    |> put_chain_rpc_urls()
    |> put_map_envs()
    |> put_token_address_books()
    |> put_token_metadata()
    |> then(&Application.put_env(:autolaunch, :launch, &1))
  end

  defp put_text_envs(config) do
    Enum.reduce(@text_envs, config, fn {key, env_name}, acc ->
      case env(env_name) do
        nil -> acc
        value -> Keyword.put(acc, key, value)
      end
    end)
  end

  defp put_numeric_env(config, key, env_name) do
    case env(env_name) do
      nil ->
        config

      value ->
        case Integer.parse(value) do
          {integer, ""} -> Keyword.put(config, key, integer)
          _ -> config
        end
    end
  end

  defp put_bool_env(config, key, env_name) do
    case env(env_name) do
      nil ->
        config

      value ->
        Keyword.put(config, key, String.downcase(value) in ["1", "true", "yes"])
    end
  end

  defp put_chain_rpc_urls(config) do
    base_mainnet_rpc = env("AUTOLAUNCH_BASE_MAINNET_RPC_URL") || env("AUTOLAUNCH_RPC_URL")
    base_sepolia_rpc = env("AUTOLAUNCH_BASE_SEPOLIA_RPC_URL")

    config
    |> put_map_value(:chain_rpc_urls, 8_453, base_mainnet_rpc)
    |> put_map_value(:chain_rpc_urls, 84_532, base_sepolia_rpc)
  end

  defp put_map_envs(config) do
    Enum.reduce(@map_envs, config, fn {key, entries}, acc ->
      Enum.reduce(entries, acc, fn {chain_id, env_name}, inner ->
        put_map_value(inner, key, chain_id, env(env_name))
      end)
    end)
  end

  defp put_token_address_books(config) do
    config
    |> put_map_value(
      :auction_quote_token_addresses,
      8_453,
      env("AUTOLAUNCH_AUCTION_QUOTE_TOKEN_ADDRESS") ||
        BaseChain.canonical_regent_address!(8_453)
    )
    |> put_map_value(
      :revenue_usdc_addresses,
      8_453,
      env("AUTOLAUNCH_REVENUE_USDC_ADDRESS") || BaseChain.canonical_usdc_address!(8_453)
    )
    |> put_map_value(:revenue_usdc_addresses, 84_532, BaseChain.canonical_usdc_address!(84_532))
  end

  defp put_token_metadata(config) do
    config
    |> Keyword.put_new(:auction_quote_token_symbol, "REGENT")
    |> Keyword.put_new(:auction_quote_token_decimals, 18)
    |> Keyword.put_new(:revenue_usdc_symbol, "USDC")
    |> Keyword.put_new(:revenue_usdc_decimals, 6)
  end

  defp put_map_value(config, _key, _chain_id, nil), do: config

  defp put_map_value(config, key, chain_id, value) do
    values =
      config
      |> Keyword.get(key, %{})
      |> Map.put(chain_id, value)

    Keyword.put(config, key, values)
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end
end
