import Config

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

# Which chain this build runs against: `base` (the default) or `fork` (a
# hosted Base fork carrying test assets, for a public preview). Fork mode
# requires both Base descriptions below, serves with writes open, and keeps the
# Base log ledger off exactly as a local lab does.
chain_mode = Autolaunch.ChainMode.parse!(System.get_env("AUTOLAUNCH_CHAIN_MODE"))
config :autolaunch, :chain_mode, chain_mode

if chain_mode == :fork do
  config :autolaunch, :prelaunch_read_only, false
end

# Opening: the site leaves read-only mode only when this is exactly `true`.
# Unset keeps the fail-closed default; anything else stops the boot.
case System.get_env("AUTOLAUNCH_LAUNCHES_OPEN") do
  nil -> :ok
  "true" -> config :autolaunch, :prelaunch_read_only, false
  other -> raise "AUTOLAUNCH_LAUNCHES_OPEN must be true or unset, got #{inspect(other)}"
end

# One deployment description per network, in the shape the lab controllers
# write and the contracts thread writes at mainnet deployment, loaded in every
# environment. A network whose variable is unset keeps whatever the
# environment's own config says, which outside ExUnit is no deployment.
deployment_path = fn name ->
  case System.get_env(name) do
    path when is_binary(path) and path != "" -> path
    _unset -> nil
  end
end

base_deployment_path = deployment_path.("AUTOLAUNCH_BASE_DEPLOYMENT")

if chain_mode == :fork and is_nil(base_deployment_path) do
  raise "AUTOLAUNCH_CHAIN_MODE=fork needs AUTOLAUNCH_BASE_DEPLOYMENT"
end

base_deployment = base_deployment_path && Autolaunch.Lab.load!(base_deployment_path)

if base_deployment do
  config :autolaunch,
    autolaunch_base_deployment: base_deployment_path,
    autolaunch_base_deployment_id: System.fetch_env!("AUTOLAUNCH_BASE_DEPLOYMENT_ID"),
    autolaunch_base_chain_id: base_deployment.chain_id
end

# The Base Stocks description extends the Base one and is refused without it.
base_stocks_deployment_path = deployment_path.("AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT")

if chain_mode == :fork and is_nil(base_stocks_deployment_path) do
  raise "AUTOLAUNCH_CHAIN_MODE=fork needs AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT"
end

if base_stocks_deployment_path do
  if is_nil(base_deployment) do
    raise "AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT needs AUTOLAUNCH_BASE_DEPLOYMENT"
  end

  Autolaunch.Stocks.Lab.load!(base_stocks_deployment_path)
end

# The Base Stocks description extends the Base one, so a given Base description
# also replaces the environment's own Base Stocks one: this one, or none.
if base_deployment do
  config :autolaunch, :autolaunch_base_stocks_deployment, base_stocks_deployment_path
end

robinhood_deployment_path = deployment_path.("AUTOLAUNCH_ROBINHOOD_DEPLOYMENT")

if robinhood_deployment_path do
  robinhood_deployment = Autolaunch.Robinhood.Lab.load!(robinhood_deployment_path)

  config :autolaunch,
    autolaunch_robinhood_deployment: robinhood_deployment_path,
    autolaunch_robinhood_chain_id: robinhood_deployment.chain_id
end

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
migrating? = System.get_env("AUTOLAUNCH_RELEASE_COMMAND") == "migrate"

database_config =
  if config_env() == :prod and migrating? do
    Autolaunch.DatabaseConfig.release_config!()
  else
    Autolaunch.DatabaseConfig.runtime_config!(config_env())
  end

# The Base log ledger follows the Base description: its own door, its factory,
# from the block `start_blocks.factory` names. A description that names no
# start blocks keeps the ledger off; the market feeds read those chains
# directly. Under ExUnit the test environment owns this setting outright, so a
# shell that exports a description cannot start an indexer under a test run; a
# browser or lab server follows its description as production does.
exunit? = config_env() == :test and System.get_env("AUTOLAUNCH_BROWSER_TEST") != "1"

indexer_chains =
  case {exunit?, base_deployment} do
    {true, _owned_by_test} ->
      []

    {false, %{start_blocks: %{"factory" => start_block}} = deployment} ->
      [
        %{
          chain_id: deployment.chain_id,
          rpc_url: deployment.rpc_url,
          sources: [%{address: deployment.addresses["factory"], start_block: start_block}]
        }
      ]

    {false, _no_ledger} ->
      []
  end

config :autolaunch, :autolaunch_indexer_chains, indexer_chains

if database_config do
  config :autolaunch, :database_startup_enabled, true
  config :autolaunch, Autolaunch.Repo, database_config
end

# The finisher sends `migrate` for every ended auction on the launchpads this
# site describes, from its finishing wallet, which pays that gas. It runs only
# on a site switched on with AUTOLAUNCH_FINISHER_ON=true: then the site needs
# the wallet's key and runs the finishing queue. Otherwise ended auctions are
# finished by hand, and the finishing queue stays paused (config.exs).
finisher_on =
  case System.get_env("AUTOLAUNCH_FINISHER_ON") do
    nil -> false
    "true" -> not migrating?
    _other -> raise "AUTOLAUNCH_FINISHER_ON must be true or unset"
  end

if finisher_on do
  finisher_key = System.fetch_env!("AUTOLAUNCH_FINISHER_KEY")

  if Autolaunch.AuctionFinish.Wallet.private_key(finisher_key) == :error do
    raise "AUTOLAUNCH_FINISHER_KEY must be 0x and the 64 hex digits of a private key"
  end

  config :autolaunch, :auction_finisher_key, finisher_key
  config :autolaunch, Oban, queues: [auction_finishing: [limit: 1, paused: false]]
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
