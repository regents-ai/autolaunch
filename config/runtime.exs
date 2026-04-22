import Config

Code.require_file("env_local.exs", __DIR__)

if System.get_env("PHX_SERVER") do
  config :autolaunch, AutolaunchWeb.Endpoint, server: true
end

env = fn key, default ->
  Autolaunch.ConfigEnvLocal.fetch(key, default)
end

env_int = fn key, default ->
  case Integer.parse(env.(key, Integer.to_string(default))) do
    {parsed, ""} -> parsed
    _ -> default
  end
end

env_bool = fn key, default ->
  env.(key, if(default, do: "true", else: "false")) in ["1", "true", "TRUE"]
end

if config_env() != :test do
  launch_chain_id_default = if config_env() == :prod, do: 8_453, else: 84_532

  if config_env() == :dev do
    database_url =
      env.("LOCAL_DATABASE_URL", env.("DATABASE_URL", ""))

    if is_binary(database_url) and String.trim(database_url) != "" do
      config :autolaunch, Autolaunch.Repo,
        url: database_url,
        stacktrace: true,
        show_sensitive_data_on_connection_error: true,
        pool_size: 10
    else
      config :autolaunch, Autolaunch.Repo,
        username: env.("DB_USER", env.("PGUSER", System.get_env("USER") || "postgres")),
        password: env.("DB_PASS", env.("PGPASSWORD", "")),
        hostname: env.("DB_HOST", env.("PGHOST", "localhost")),
        port: env_int.("DB_PORT", 5432),
        database: env.("DB_NAME", "autolaunch_dev"),
        stacktrace: true,
        show_sensitive_data_on_connection_error: true,
        pool_size: 10
    end

    config :autolaunch, AutolaunchWeb.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: env_int.("PORT", 4002)],
      check_origin: false,
      code_reloader: true,
      debug_errors: true
  else
    config :autolaunch, AutolaunchWeb.Endpoint, http: [port: env_int.("PORT", 4002)]
  end

  config :autolaunch, :privy,
    app_id: env.("PRIVY_APP_ID", ""),
    verification_key: env.("PRIVY_VERIFICATION_KEY", "")

  config :autolaunch, :internal_shared_secret, env.("AUTOLAUNCH_INTERNAL_SHARED_SECRET", "")

  config :autolaunch, Autolaunch.Xmtp,
    rooms: [
      %{
        key: "autolaunch_wire",
        name: "Autolaunch Wire",
        description: "The shared Autolaunch chat room.",
        app_data: "autolaunch-wire",
        agent_private_key: env.("AUTOLAUNCH_XMTP_AGENT_PRIVATE_KEY", ""),
        moderator_wallets: [],
        capacity: 200,
        presence_timeout_ms: :timer.minutes(2),
        presence_check_interval_ms: :timer.seconds(30),
        policy_options: %{
          allowed_kinds: [:human, :agent],
          required_claims: %{}
        }
      }
    ]

  config :autolaunch, :siwa,
    internal_url: env.("SIWA_INTERNAL_URL", "http://siwa-sidecar:4100"),
    shared_secret: env.("SIWA_SHARED_SECRET", ""),
    http_connect_timeout_ms: env_int.("SIWA_HTTP_CONNECT_TIMEOUT_MS", 2_000),
    http_receive_timeout_ms: env_int.("SIWA_HTTP_RECEIVE_TIMEOUT_MS", 5_000)

  config :autolaunch, :launch,
    chain_id: env_int.("AUTOLAUNCH_CHAIN_ID", launch_chain_id_default),
    allow_unverified_owner: env_bool.("AUTOLAUNCH_ALLOW_UNVERIFIED_OWNER", false),
    deploy_binary: env.("AUTOLAUNCH_DEPLOY_BINARY", "forge"),
    deploy_workdir: env.("AUTOLAUNCH_DEPLOY_WORKDIR", ""),
    deploy_script_target: env.("AUTOLAUNCH_DEPLOY_SCRIPT_TARGET", ""),
    deploy_timeout_ms: env_int.("AUTOLAUNCH_DEPLOY_TIMEOUT_MS", 180_000),
    deploy_output_marker: env.("AUTOLAUNCH_DEPLOY_OUTPUT_MARKER", "CCA_RESULT_JSON:"),
    rpc_url: env.("AUTOLAUNCH_RPC_URL", ""),
    cca_factory_address:
      env.("AUTOLAUNCH_CCA_FACTORY_ADDRESS", "0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5"),
    pool_manager_address: env.("AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER", ""),
    position_manager_address: env.("AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER", ""),
    usdc_address: env.("AUTOLAUNCH_USDC_ADDRESS", ""),
    revenue_share_factory_address: env.("AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS", ""),
    revenue_ingress_factory_address: env.("AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS", ""),
    pool_manager_addresses: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_UNISWAP_V4_POOL_MANAGER", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_UNISWAP_V4_POOL_MANAGER", "")
    },
    usdc_addresses: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_USDC_ADDRESS", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_USDC_ADDRESS", "")
    },
    revenue_share_factory_addresses: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_REVENUE_SHARE_FACTORY_ADDRESS", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_REVENUE_SHARE_FACTORY_ADDRESS", "")
    },
    revenue_ingress_factory_addresses: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_REVENUE_INGRESS_FACTORY_ADDRESS", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_REVENUE_INGRESS_FACTORY_ADDRESS", "")
    },
    lbp_strategy_factory_address: env.("AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS", ""),
    token_factory_address: env.("AUTOLAUNCH_TOKEN_FACTORY_ADDRESS", ""),
    erc8004_subgraph_url: env.("AUTOLAUNCH_ERC8004_SUBGRAPH_URL", ""),
    identity_registry_address: env.("AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS", ""),
    chain_rpc_urls: %{
      1 => env.("AUTOLAUNCH_ETH_MAINNET_RPC_URL", ""),
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_RPC_URL", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_RPC_URL", ""),
      11_155_111 => env.("AUTOLAUNCH_ETH_SEPOLIA_RPC_URL", "")
    },
    erc8004_subgraph_urls: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_ERC8004_SUBGRAPH_URL", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_ERC8004_SUBGRAPH_URL", "")
    },
    identity_registry_addresses: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_IDENTITY_REGISTRY_ADDRESS", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_IDENTITY_REGISTRY_ADDRESS", "")
    },
    regent_multisig_address:
      env.("REGENT_MULTISIG_ADDRESS", "0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e"),
    deploy_account: env.("AUTOLAUNCH_DEPLOY_ACCOUNT", ""),
    deploy_password: env.("AUTOLAUNCH_DEPLOY_PASSWORD", ""),
    deploy_private_key: env.("AUTOLAUNCH_DEPLOY_PRIVATE_KEY", ""),
    mock_deploy: env_bool.("AUTOLAUNCH_MOCK_DEPLOY", false)

  config :autolaunch, :regent_staking,
    chain_id: env_int.("REGENT_STAKING_CHAIN_ID", 84_532),
    chain_label: env.("REGENT_STAKING_CHAIN_LABEL", "Base Sepolia"),
    rpc_url: env.("REGENT_STAKING_RPC_URL", ""),
    contract_address: env.("REGENT_REVENUE_STAKING_ADDRESS", "")

  config :agent_world, :world_id,
    app_id: env.("WORLD_ID_APP_ID", ""),
    action: env.("WORLD_ID_ACTION", "agentbook-registration"),
    rp_id: env.("WORLD_ID_RP_ID", ""),
    signing_key: env.("WORLD_ID_SIGNING_KEY", ""),
    ttl_seconds: env_int.("WORLD_ID_TTL_SECONDS", 300)

  config :agent_world, :networks, %{
    "world" => %{
      rpc_url: env.("WORLDCHAIN_RPC_URL", ""),
      contract_address:
        env.("WORLDCHAIN_AGENTBOOK_ADDRESS", "0xA23aB2712eA7BBa896930544C7d6636a96b944dA"),
      relay_url: env.("WORLDCHAIN_AGENTBOOK_RELAY_URL", "")
    },
    "base" => %{
      rpc_url: env.("BASE_MAINNET_RPC_URL", ""),
      contract_address:
        env.("BASE_AGENTBOOK_ADDRESS", "0xE1D1D3526A6FAa37eb36bD10B933C1b77f4561a4"),
      relay_url: env.("BASE_AGENTBOOK_RELAY_URL", "")
    },
    "base-sepolia" => %{
      rpc_url: env.("BASE_SEPOLIA_RPC_URL", ""),
      contract_address:
        env.(
          "BASE_SEPOLIA_AGENTBOOK_ADDRESS",
          "0xA23aB2712eA7BBa896930544C7d6636a96b944dA"
        ),
      relay_url: env.("BASE_SEPOLIA_AGENTBOOK_RELAY_URL", "")
    }
  }
end

if config_env() == :prod do
  database_url =
    env.("DATABASE_URL", "") ||
      raise """
      environment variable DATABASE_URL is missing.
      """

  secret_key_base =
    env.("SECRET_KEY_BASE", "") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      """

  host = env.("PHX_HOST", "autolaunch.sh")

  config :autolaunch, Autolaunch.Repo,
    url: database_url,
    pool_size: String.to_integer(env.("POOL_SIZE", "10"))

  config :autolaunch, :dns_cluster_query, env.("DNS_CLUSTER_QUERY", "")

  config :autolaunch, AutolaunchWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: env_int.("PORT", 4002)],
    secret_key_base: secret_key_base
end
