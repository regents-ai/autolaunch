import Config

if System.get_env("PHX_SERVER") do
  config :autolaunch, AutolaunchWeb.Endpoint, server: true
end

env_local_path = Path.expand("../.env.local", __DIR__)

env_local_values = fn ->
  case File.read(env_local_path) do
    {:ok, contents} ->
      contents
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" or String.starts_with?(trimmed, "#") ->
            acc

          true ->
            normalized =
              if String.starts_with?(trimmed, "export ") do
                trimmed |> String.replace_prefix("export ", "") |> String.trim()
              else
                trimmed
              end

            case String.split(normalized, "=", parts: 2) do
              [key, value] ->
                Map.put(
                  acc,
                  String.trim(key),
                  value
                  |> String.trim()
                  |> String.trim_leading("\"")
                  |> String.trim_trailing("\"")
                  |> String.trim_leading("'")
                  |> String.trim_trailing("'")
                )

              _ ->
                acc
            end
        end
      end)

    _ ->
      %{}
  end
end

env = fn key, default ->
  System.get_env(key) || Map.get(env_local_values.(), key, default)
end

env_required = fn key ->
  case env.(key, "") do
    value when is_binary(value) ->
      value
      |> String.trim()
      |> case do
        "" -> raise "environment variable #{key} is missing or blank."
        trimmed -> trimmed
      end

    _ ->
      raise "environment variable #{key} is missing or blank."
  end
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

env_list = fn key, default ->
  key
  |> env.(default)
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end

config :sentry,
  dsn: System.get_env("SENTRY_DSN"),
  environment_name: System.get_env("SENTRY_ENVIRONMENT", "production"),
  release: System.get_env("SENTRY_RELEASE"),
  json_library: Jason,
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  in_app_otp_apps: [:autolaunch]

if config_env() != :test do
  base_mainnet_rpc_url = "https://base-mainnet.g.alchemy.com/v2/mh8bSk613dgCNswQaicqncntni1gOg3o"
  launch_chain_id_default = 8_453
  launch_chain_id = env_int.("AUTOLAUNCH_CHAIN_ID", launch_chain_id_default)

  canonical_usdc_addresses = %{
    8_453 => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
    84_532 => "0x036cbd53842c5426634e7929541ec2318f3dcf7e"
  }

  if config_env() == :dev do
    database_url =
      env.("LOCAL_DATABASE_URL", env.("DATABASE_URL", ""))

    if is_binary(database_url) and String.trim(database_url) != "" do
      config :autolaunch, Autolaunch.Repo,
        url: database_url,
        stacktrace: true,
        show_sensitive_data_on_connection_error: true,
        after_connect: {Postgrex, :query!, [~s(SET search_path TO "autolaunch",public), []]},
        migration_default_prefix: "autolaunch",
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
        after_connect: {Postgrex, :query!, [~s(SET search_path TO "autolaunch",public), []]},
        migration_default_prefix: "autolaunch",
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

  config :autolaunch, :siwa,
    internal_url: env.("SIWA_INTERNAL_URL", "http://siwa-sidecar:4100"),
    http_connect_timeout_ms: env_int.("SIWA_HTTP_CONNECT_TIMEOUT_MS", 2_000),
    http_receive_timeout_ms: env_int.("SIWA_HTTP_RECEIVE_TIMEOUT_MS", 5_000)

  config :autolaunch, :launch_job_poller,
    enabled: env_bool.("AUTOLAUNCH_LAUNCH_JOB_POLLER_ENABLED", config_env() == :prod),
    interval_ms: env_int.("AUTOLAUNCH_LAUNCH_JOB_POLLER_INTERVAL_MS", 2_000),
    lease_timeout_ms: env_int.("AUTOLAUNCH_LAUNCH_JOB_LEASE_TIMEOUT_MS", :timer.minutes(10))

  config :autolaunch, :auction_sync,
    enabled: env_bool.("AUTOLAUNCH_AUCTION_SYNC_ENABLED", config_env() == :prod),
    interval_ms: env_int.("AUTOLAUNCH_AUCTION_SYNC_INTERVAL_MS", 30_000),
    batch_size: env_int.("AUTOLAUNCH_AUCTION_SYNC_BATCH_SIZE", 20),
    snapshot_ttl_seconds: env_int.("AUTOLAUNCH_AUCTION_SYNC_SNAPSHOT_TTL_SECONDS", 45)

  config :autolaunch, :prelaunch_uploads,
    root_dir:
      env.(
        "AUTOLAUNCH_UPLOAD_DIR",
        Path.expand("../tmp/prelaunch-assets", __DIR__)
      )

  config :autolaunch, :launch,
    chain_id: launch_chain_id,
    allow_unverified_owner: env_bool.("AUTOLAUNCH_ALLOW_UNVERIFIED_OWNER", false),
    deploy_binary: env.("AUTOLAUNCH_DEPLOY_BINARY", "forge"),
    deploy_workdir: env.("AUTOLAUNCH_DEPLOY_WORKDIR", ""),
    deploy_script_target: env.("AUTOLAUNCH_DEPLOY_SCRIPT_TARGET", ""),
    deploy_timeout_ms: env_int.("AUTOLAUNCH_DEPLOY_TIMEOUT_MS", 180_000),
    deploy_output_marker: env.("AUTOLAUNCH_DEPLOY_OUTPUT_MARKER", "CCA_RESULT_JSON:"),
    rpc_url: env.("AUTOLAUNCH_RPC_URL", base_mainnet_rpc_url),
    cca_factory_address: env.("AUTOLAUNCH_CCA_FACTORY_ADDRESS", ""),
    pool_manager_address: env.("AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER", ""),
    position_manager_address: env.("AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER", ""),
    usdc_address: Map.get(canonical_usdc_addresses, launch_chain_id, ""),
    revenue_share_factory_address: env.("AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS", ""),
    existing_token_revenue_factory_address:
      env.("AUTOLAUNCH_EXISTING_TOKEN_REVENUE_FACTORY_ADDRESS", ""),
    deferred_autolaunch_factory_address:
      env.("AUTOLAUNCH_DEFERRED_AUTOLAUNCH_FACTORY_ADDRESS", ""),
    revenue_ingress_factory_address: env.("AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS", ""),
    pool_manager_addresses: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_UNISWAP_V4_POOL_MANAGER", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_UNISWAP_V4_POOL_MANAGER", "")
    },
    usdc_addresses: %{
      8_453 => Map.fetch!(canonical_usdc_addresses, 8_453),
      84_532 => Map.fetch!(canonical_usdc_addresses, 84_532)
    },
    revenue_share_factory_addresses: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_REVENUE_SHARE_FACTORY_ADDRESS", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_REVENUE_SHARE_FACTORY_ADDRESS", "")
    },
    revenue_ingress_factory_addresses: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_REVENUE_INGRESS_FACTORY_ADDRESS", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_REVENUE_INGRESS_FACTORY_ADDRESS", "")
    },
    lbp_strategy_factory_addresses: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_LBP_STRATEGY_FACTORY_ADDRESS", ""),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_LBP_STRATEGY_FACTORY_ADDRESS", "")
    },
    lbp_strategy_factory_address: env.("AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS", ""),
    token_factory_address: env.("AUTOLAUNCH_TOKEN_FACTORY_ADDRESS", ""),
    token_metadata_description: env.("AUTOLAUNCH_TOKEN_METADATA_DESCRIPTION", ""),
    token_metadata_website: env.("AUTOLAUNCH_TOKEN_METADATA_WEBSITE", ""),
    token_metadata_image: env.("AUTOLAUNCH_TOKEN_METADATA_IMAGE", ""),
    erc8004_subgraph_url: env.("AUTOLAUNCH_ERC8004_SUBGRAPH_URL", ""),
    identity_registry_address: env.("AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS", ""),
    factory_owner_address: env.("AUTOLAUNCH_FACTORY_OWNER_ADDRESS", ""),
    strategy_operator: env.("STRATEGY_OPERATOR", ""),
    official_pool_fee: env.("OFFICIAL_POOL_FEE", "0"),
    official_pool_tick_spacing: env.("OFFICIAL_POOL_TICK_SPACING", "60"),
    cca_tick_spacing_q96: env.("CCA_TICK_SPACING_Q96", ""),
    cca_floor_price_q96: env.("CCA_FLOOR_PRICE_Q96", ""),
    cca_validation_hook: env.("CCA_VALIDATION_HOOK", ""),
    auction_duration_blocks: env.("AUCTION_DURATION_BLOCKS", "86400"),
    cca_prebid_blocks: env.("CCA_PREBID_BLOCKS", "0"),
    cca_final_block_bps: env.("CCA_FINAL_BLOCK_BPS", "3000"),
    cca_start_block_offset: env.("CCA_START_BLOCK_OFFSET", "300"),
    cca_claim_block_offset: env.("CCA_CLAIM_BLOCK_OFFSET", "64"),
    lbp_migration_block_offset: env.("LBP_MIGRATION_BLOCK_OFFSET", "128"),
    lbp_sweep_block_offset: env.("LBP_SWEEP_BLOCK_OFFSET", "256"),
    chain_rpc_urls: %{
      8_453 => env.("AUTOLAUNCH_BASE_MAINNET_RPC_URL", base_mainnet_rpc_url),
      84_532 => env.("AUTOLAUNCH_BASE_SEPOLIA_RPC_URL", "")
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
    deploy_sender: env.("AUTOLAUNCH_DEPLOY_SENDER", ""),
    deploy_password: env.("AUTOLAUNCH_DEPLOY_PASSWORD", ""),
    mock_deploy: env_bool.("AUTOLAUNCH_MOCK_DEPLOY", false)

  config :autolaunch, :regent_staking,
    chain_id: env_int.("REGENT_STAKING_CHAIN_ID", 8_453),
    chain_label: env.("REGENT_STAKING_CHAIN_LABEL", "Base"),
    rpc_url: env.("REGENT_STAKING_RPC_URL", base_mainnet_rpc_url),
    ethereum_rpc_url: env.("ETHEREUM_RPC_URL", ""),
    contract_address: env.("REGENT_REVENUE_STAKING_ADDRESS", ""),
    operator_wallets: env_list.("REGENT_STAKING_OPERATOR_WALLETS", "")

  config :autolaunch, :contract_admin,
    operator_wallets:
      env_list.(
        "AUTOLAUNCH_CONTRACT_ADMIN_OPERATOR_WALLETS",
        "0xB26A3609acD791e2eA3f1900619C910B45705adD"
      )

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
      rpc_url: env.("BASE_MAINNET_RPC_URL", base_mainnet_rpc_url),
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
  database_url = env_required.("DATABASE_URL")

  secret_key_base = env_required.("SECRET_KEY_BASE")

  host = env.("PHX_HOST", "autolaunch.sh")
  url_scheme = env.("PHX_URL_SCHEME", "https")

  url_port =
    env_int.("PHX_URL_PORT", if(url_scheme == "https", do: 443, else: env_int.("PORT", 4002)))

  check_origin = env_list.("PHX_CHECK_ORIGIN", "#{url_scheme}://#{host}:#{url_port}")

  config :autolaunch, Autolaunch.Repo,
    url: database_url,
    ssl: env_bool.("DATABASE_SSL", true),
    prepare: :unnamed,
    after_connect: {Postgrex, :query!, [~s(SET search_path TO "autolaunch",public), []]},
    pool_size: String.to_integer(env.("ECTO_POOL_SIZE", "5")),
    migration_default_prefix: "autolaunch",
    migration_source: "schema_migrations_autolaunch"

  config :autolaunch, :dns_cluster_query, env.("DNS_CLUSTER_QUERY", "")

  config :autolaunch, AutolaunchWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: env_int.("PORT", 4002)],
    check_origin: check_origin,
    secret_key_base: secret_key_base
end
