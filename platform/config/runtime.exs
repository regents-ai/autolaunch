import Config

database_schema = System.get_env("AUTOLAUNCH_DB_SCHEMA", "public")

unless database_schema in ["public", "autolaunch_app"] do
  raise "AUTOLAUNCH_DB_SCHEMA must be public or autolaunch_app"
end

config :autolaunch, Autolaunch.Repo,
  default_prefix: database_schema,
  migration_default_prefix: database_schema

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# The Privy application's public verification keys, as PEM blocks in one
# variable: one key ordinarily, and during a key rotation the keys Privy's
# published key set lists, newest first. The set is bounded, is read only from
# this variable, and never from a URL or from a token. The session boundary
# and the shared identity API both verify against this same set. The singular
# option remains available for callers using the existing single-PEM contract.
privy_max_verification_keys = 4

privy_verification_keys =
  case System.get_env("PRIVY_VERIFICATION_KEY") do
    nil ->
      []

    value ->
      value
      |> String.replace("\\r\\n", "\n")
      |> String.replace("\\n", "\n")
      |> then(&Regex.scan(~r/-----BEGIN PUBLIC KEY-----.*?-----END PUBLIC KEY-----/s, &1))
      |> List.flatten()
  end

if length(privy_verification_keys) > privy_max_verification_keys do
  raise "PRIVY_VERIFICATION_KEY holds more than #{privy_max_verification_keys} PEM public keys"
end

config :autolaunch, :privy,
  app_id: System.get_env("PRIVY_APP_ID"),
  verification_key: List.first(privy_verification_keys),
  verification_keys: privy_verification_keys

# A lab site taking real sign-ins has nothing to verify them with unless both
# public inputs are present, so it stops at boot rather than at the first
# Sign in press.
if System.get_env("AUTOLAUNCH_LAB_AUTH") == "privy" and
     (System.get_env("PRIVY_APP_ID") in [nil, ""] or privy_verification_keys == []) do
  raise "AUTOLAUNCH_LAB_AUTH=privy needs PRIVY_APP_ID and PRIVY_VERIFICATION_KEY (PEM public keys)"
end

x_oauth_client_id =
  case System.get_env("X_OAUTH_CLIENT_ID") do
    value when is_binary(value) ->
      case String.trim(value) do
        "" -> nil
        value -> value
      end

    _missing ->
      nil
  end

config :autolaunch, :x_oauth_client_id, x_oauth_client_id

# Which chain this build runs against: `base` (real Base, the default) or
# `fork` (a hosted Base fork carrying the lab contract graph, for a public
# preview). Fork mode is admitted in every environment, production included;
# it requires both lab configurations below, serves with writes open, and
# keeps the Base log ledger off exactly as a lab does.
chain_mode = Autolaunch.ChainMode.parse!(System.get_env("AUTOLAUNCH_CHAIN_MODE"))
config :autolaunch, :chain_mode, chain_mode

if chain_mode == :fork do
  config :autolaunch, :prelaunch_read_only, false
end

autolaunch_lab_path = System.get_env("AUTOLAUNCH_LAB_CONFIG")

autolaunch_lab =
  case {chain_mode, config_env(), autolaunch_lab_path} do
    {:fork, _env, path} when path in [nil, ""] ->
      raise "AUTOLAUNCH_CHAIN_MODE=fork needs AUTOLAUNCH_LAB_CONFIG"

    {:fork, _env, path} ->
      Autolaunch.Lab.load!(path, :fork)

    {:base, _env, nil} ->
      nil

    {:base, _env, ""} ->
      nil

    {:base, :prod, _path} ->
      raise "AUTOLAUNCH_LAB_CONFIG is development/test only"

    {:base, env, path} when env in [:dev, :test] ->
      Autolaunch.Lab.load!(path, :base)
  end

config :autolaunch, :autolaunch_lab_enabled, not is_nil(autolaunch_lab)
config :autolaunch, :autolaunch_lab_config_path, autolaunch_lab && autolaunch_lab.path

if autolaunch_lab do
  config :autolaunch,
         :autolaunch_lab_run_id,
         System.fetch_env!("AUTOLAUNCH_FORK_RUN_ID")
end

# The Stocks lab extends a running Agent lab and is refused without one.
autolaunch_stocks_lab =
  case {chain_mode, config_env(), System.get_env("AUTOLAUNCH_STOCKS_LAB_CONFIG")} do
    {:fork, _env, path} when path in [nil, ""] ->
      raise "AUTOLAUNCH_CHAIN_MODE=fork needs AUTOLAUNCH_STOCKS_LAB_CONFIG"

    {:base, _env, nil} ->
      nil

    {:base, _env, ""} ->
      nil

    {:base, :prod, _path} ->
      raise "AUTOLAUNCH_STOCKS_LAB_CONFIG is development/test only"

    {:base, _env, _path} when is_nil(autolaunch_lab) ->
      raise "AUTOLAUNCH_STOCKS_LAB_CONFIG needs AUTOLAUNCH_LAB_CONFIG"

    {mode, _env, path} ->
      loaded = Autolaunch.Stocks.Lab.load!(path, mode)

      if loaded.agent_lab_config != autolaunch_lab.path do
        raise "AUTOLAUNCH_STOCKS_LAB_CONFIG names a different Agent lab than AUTOLAUNCH_LAB_CONFIG"
      end

      loaded
  end

config :autolaunch, :autolaunch_stocks_lab_enabled, not is_nil(autolaunch_stocks_lab)

config :autolaunch,
       :autolaunch_stocks_lab_config_path,
       autolaunch_stocks_lab && autolaunch_stocks_lab.path

# The Robinhood lab is its own blank local chain (31338), development and test only.
autolaunch_robinhood_lab =
  case {config_env(), System.get_env("AUTOLAUNCH_ROBINHOOD_LAB_CONFIG")} do
    {_env, nil} -> nil
    {_env, ""} -> nil
    {:prod, _path} -> raise "AUTOLAUNCH_ROBINHOOD_LAB_CONFIG is development/test only"
    {_env, path} -> Autolaunch.Robinhood.Lab.load!(path)
  end

config :autolaunch, :autolaunch_robinhood_lab_enabled, not is_nil(autolaunch_robinhood_lab)

config :autolaunch,
       :autolaunch_robinhood_lab_config_path,
       autolaunch_robinhood_lab && autolaunch_robinhood_lab.path

# Test funds: at most one grant per wallet and asset within this many seconds;
# `0` is no cooldown. Unset means an hour on a public fork preview and none
# on a local lab.
config :autolaunch,
       :faucet_cooldown_seconds,
       Autolaunch.ChainMode.faucet_cooldown_seconds!(
         chain_mode,
         System.get_env("AUTOLAUNCH_FAUCET_COOLDOWN_SECONDS")
       )

# The release sets this on its migration commands, and only on those, so the
# migration boot can take a direct connection while the web boot takes the
# pooled one.
migrating? = System.get_env("AUTOLAUNCH_RELEASE_COMMAND") in ["migrate", "bootstrap"]

database_config =
  if config_env() == :prod and migrating? do
    Autolaunch.DatabaseConfig.release_config!()
  else
    Autolaunch.DatabaseConfig.runtime_config!(config_env())
  end

# The log ledger follows one chain per dedicated endpoint, separate from the
# simple-read RPC: Base through AUTOLAUNCH_INDEXER_RPC_URL, watching the factory
# the evidence manifest admits from AUTOLAUNCH_INDEXER_FACTORY_START_BLOCK, and
# Robinhood through AUTOLAUNCH_ROBINHOOD_INDEXER_RPC_URL with its chain id,
# launchpad address and start block named beside it. The test environment owns
# this setting outright so a shell that exports an endpoint cannot start an
# indexer under a test run, and a local lab run keeps the ledger off.
block_env! = fn name ->
  case name |> System.fetch_env!() |> Integer.parse() do
    {block, ""} when block >= 0 -> block
    _malformed -> raise "#{name} must be a nonnegative block number"
  end
end

chain_env! = fn name ->
  case name |> System.fetch_env!() |> Integer.parse() do
    {chain_id, ""} when chain_id > 0 -> chain_id
    _malformed -> raise "#{name} must be a positive chain id"
  end
end

indexer_chain = fn url_name, chain_id, sources ->
  case System.get_env(url_name) do
    url when is_binary(url) and url != "" ->
      [%{chain_id: chain_id.(), rpc_url: url, sources: sources.()}]

    _unset ->
      []
  end
end

indexer_chains =
  if config_env() == :test or autolaunch_lab do
    []
  else
    indexer_chain.("AUTOLAUNCH_INDEXER_RPC_URL", fn -> 8453 end, fn ->
      case Autolaunch.Chain.Abi.factory_address() do
        {:ok, address} ->
          [
            %{
              address: address,
              start_block: block_env!.("AUTOLAUNCH_INDEXER_FACTORY_START_BLOCK")
            }
          ]

        :none ->
          []
      end
    end) ++
      indexer_chain.(
        "AUTOLAUNCH_ROBINHOOD_INDEXER_RPC_URL",
        fn -> chain_env!.("AUTOLAUNCH_ROBINHOOD_CHAIN_ID") end,
        fn ->
          [
            %{
              address: System.fetch_env!("AUTOLAUNCH_ROBINHOOD_FACTORY_ADDRESS"),
              start_block: block_env!.("AUTOLAUNCH_ROBINHOOD_FACTORY_START_BLOCK")
            }
          ]
        end
      )
  end

config :autolaunch, :autolaunch_indexer_chains, indexer_chains

if database_config do
  config :autolaunch, :database_startup_enabled, true
  config :autolaunch, Autolaunch.Repo, database_config
end

if config_env() == :prod do
  config :autolaunch, :session_options, secure: true, http_only: true

  unless migrating? do
    # The serving site reads one canonical `safe` Base block through this
    # endpoint. Migration machines do not start the web or chain-read paths and
    # therefore receive no RPC credential.
    config :autolaunch, :base_read_rpc_url, System.fetch_env!("BASE_READ_RPC_URL")

    host = String.trim(System.fetch_env!("PHX_HOST"))
    secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

    if host == "" do
      raise "PHX_HOST must not be empty"
    end

    if byte_size(secret_key_base) < 64 do
      raise "SECRET_KEY_BASE must be at least 64 bytes"
    end

    config :autolaunch, AutolaunchWeb.Endpoint,
      server: true,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: String.to_integer(System.get_env("PORT", "4000"))
      ],
      secret_key_base: secret_key_base
  end
end
