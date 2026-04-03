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

  config :autolaunch, :siwa,
    internal_url: env.("SIWA_INTERNAL_URL", "http://siwa-sidecar:4100"),
    shared_secret: env.("SIWA_SHARED_SECRET", ""),
    http_connect_timeout_ms: env_int.("SIWA_HTTP_CONNECT_TIMEOUT_MS", 2_000),
    http_receive_timeout_ms: env_int.("SIWA_HTTP_RECEIVE_TIMEOUT_MS", 5_000),
    skip_http_verify: env_bool.("SIWA_SKIP_HTTP_VERIFY", false)

  config :autolaunch, :launch,
    chain_id: 11_155_111,
    allow_unverified_owner: env_bool.("AUTOLAUNCH_ALLOW_UNVERIFIED_OWNER", false),
    deploy_binary: env.("AUTOLAUNCH_DEPLOY_BINARY", "forge"),
    deploy_workdir: env.("AUTOLAUNCH_DEPLOY_WORKDIR", ""),
    deploy_script_target: env.("AUTOLAUNCH_DEPLOY_SCRIPT_TARGET", ""),
    deploy_output_marker: env.("AUTOLAUNCH_DEPLOY_OUTPUT_MARKER", "CCA_RESULT_JSON:"),
    eth_sepolia_rpc_url: env.("ETH_SEPOLIA_RPC_URL", ""),
    eth_sepolia_factory_address:
      env.("ETH_SEPOLIA_FACTORY_ADDRESS", "0xCCccCcCAE7503Cac057829BF2811De42E16e0bD5"),
    eth_sepolia_pool_manager_address: env.("ETH_SEPOLIA_UNISWAP_V4_POOL_MANAGER", ""),
    eth_sepolia_position_manager_address: env.("ETH_SEPOLIA_UNISWAP_V4_POSITION_MANAGER", ""),
    eth_sepolia_usdc_address: env.("ETH_SEPOLIA_USDC_ADDRESS", ""),
    revenue_share_factory_address: env.("REVENUE_SHARE_FACTORY_ADDRESS", ""),
    revenue_ingress_factory_address: env.("REVENUE_INGRESS_FACTORY_ADDRESS", ""),
    lbp_strategy_factory_address: env.("LBP_STRATEGY_FACTORY_ADDRESS", ""),
    token_factory_address: env.("TOKEN_FACTORY_ADDRESS", ""),
    erc8004_sepolia_subgraph_url: env.("ERC8004_SEPOLIA_SUBGRAPH_URL", ""),
    regent_multisig_address:
      env.("REGENT_MULTISIG_ADDRESS", "0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e"),
    deploy_account: env.("AUTOLAUNCH_DEPLOY_ACCOUNT", ""),
    deploy_password: env.("AUTOLAUNCH_DEPLOY_PASSWORD", ""),
    deploy_private_key: env.("AUTOLAUNCH_DEPLOY_PRIVATE_KEY", ""),
    mock_deploy: env_bool.("AUTOLAUNCH_MOCK_DEPLOY", false)

  config :autolaunch, :regent_staking,
    chain_id: 8_453,
    chain_label: "Base",
    rpc_url: env.("BASE_MAINNET_RPC_URL", ""),
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
