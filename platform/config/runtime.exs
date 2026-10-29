import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# The Privy accounts that may give Credits, handle refunds and read the saved
# errors at /admin/errors, comma separated.
if admins = System.get_env("REGENT_CREDITS_ADMINS") do
  config :regent_credits,
    admins: admins |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# This site's own key for reading what paired agents have done from the sign-in
# service (RegentAgents.Activity), for the lines under the account menu's agents.
# Without it those lines stay empty.
config :regent_agents, :activity_read_token, System.get_env("SIWA_ACTIVITY_READ_TOKEN")

# The Privy application's public verification key, as one PEM block. The
# session boundary and the shared identity API both verify against it; it is
# read only from this variable, never from a URL or from a token.
privy_verification_key =
  case System.get_env("PRIVY_VERIFICATION_KEY") do
    nil -> nil
    value -> value |> String.replace("\\r\\n", "\n") |> String.replace("\\n", "\n")
  end

config :autolaunch, :privy,
  app_id: System.get_env("PRIVY_APP_ID"),
  verification_key: privy_verification_key

# Without its Privy settings a local server answers every page while nobody can
# sign in, so it refuses to start. Other mix tasks, such as migrations and code
# generation, run without them.
if config_env() == :dev and Phoenix.Endpoint.server?(:autolaunch, AutolaunchWeb.Endpoint) do
  for name <- ~w(PRIVY_APP_ID PRIVY_VERIFICATION_KEY), System.get_env(name, "") == "" do
    raise """
    #{name} is not set, so nobody could sign in. Set PRIVY_APP_ID and PRIVY_VERIFICATION_KEY before starting the site.
    """
  end
end

# The browser walk's server (playwright.config.ts) writes its lines in production's
# shape to a file, which test/browser/visits.spec.ts reads to replay a visit. The
# tests print only warnings (config/test.exs); the walk's server writes its visit
# lines too.
if config_env() == :test and System.get_env("AUTOLAUNCH_WALK") == "true" do
  config :logger, level: :info

  config :logger, :default_handler,
    config: [file: String.to_charlist(Path.expand("../tmp/walk-lines.jsonl", __DIR__))],
    formatter: LoggerJSON.Formatters.Basic.new(metadata: AutolaunchWeb.VisitLog.fields())
end

# A lab site taking real sign-ins has nothing to verify them with unless both
# public inputs are present, so it stops at boot rather than at the first
# Sign in press.
if System.get_env("AUTOLAUNCH_LAB_AUTH") == "privy" and
     (System.get_env("PRIVY_APP_ID") in [nil, ""] or privy_verification_key in [nil, ""]) do
  raise "AUTOLAUNCH_LAB_AUTH=privy needs PRIVY_APP_ID and PRIVY_VERIFICATION_KEY (a PEM public key)"
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

# The motion lab at /animations (AutolaunchWeb.Showcase). Unset, it is off in
# production and public elsewhere; any value but "public" or "off" stops the boot.
showcase =
  case {config_env(), System.get_env("AUTOLAUNCH_SHOWCASE")} do
    {_env, "public"} -> :public
    {_env, "off"} -> :off
    {:prod, nil} -> :off
    {_env, nil} -> :public
    {_env, _setting} -> raise ~s(AUTOLAUNCH_SHOWCASE must be "public" or "off")
  end

config :autolaunch, :showcase, showcase

# Opening: the site leaves read-only mode only when this is exactly `true`.
# Unset keeps the fail-closed default; anything else stops the boot.
case System.get_env("AUTOLAUNCH_LAUNCHES_OPEN") do
  nil -> :ok
  "true" -> config :autolaunch, :prelaunch_read_only, false
  other -> raise "AUTOLAUNCH_LAUNCHES_OPEN must be true or unset, got #{inspect(other)}"
end

# The release sets this on its migration command (fly.toml's release_command),
# and only on that, so the migration boot takes the release login while the web
# boot takes the serving one.
migrating? = System.get_env("AUTOLAUNCH_RELEASE_COMMAND") == "migrate"

# One deployment description per network, in the shape the lab controllers
# write and the contracts thread writes at mainnet deployment, loaded in every
# environment. A network whose variable is unset keeps whatever the
# environment's own config says, which outside ExUnit is no deployment. The
# migration boot reads none: it starts neither the web nor the chain reads.
deployment_path = fn name ->
  case {migrating?, System.get_env(name)} do
    {false, path} when is_binary(path) and path != "" -> path
    _none -> nil
  end
end

base_deployment_path = deployment_path.("AUTOLAUNCH_BASE_DEPLOYMENT")

base_deployment = base_deployment_path && Autolaunch.Lab.load!(base_deployment_path)

if base_deployment do
  config :autolaunch,
    autolaunch_base_deployment: base_deployment_path,
    autolaunch_base_deployment_id: System.fetch_env!("AUTOLAUNCH_BASE_DEPLOYMENT_ID"),
    autolaunch_base_chain_id: base_deployment.chain_id
end

# The Base Stocks description extends the Base one and is refused without it.
base_stocks_deployment_path = deployment_path.("AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT")

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

database_config =
  if config_env() == :prod and migrating? do
    Autolaunch.DatabaseConfig.release_config!()
  else
    Autolaunch.DatabaseConfig.runtime_config!(config_env())
  end

# The Base log ledger follows the Base description: its own door, its factory,
# from the block `start_blocks.factory` names. A description that names no
# start blocks keeps the ledger off; each auction's reading job reads those
# chains directly. Under ExUnit the test environment owns this setting outright, so a
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

  unless migrating? do
    config :autolaunch,
           Autolaunch.Notifications,
           Autolaunch.DatabaseConfig.notifications_config!(config_env())
  end
end

# Covered calls are offered only on a site switched on with
# AUTOLAUNCH_COVERED_CALLS=true; then the description of their contracts is
# required, and it extends the Base description. Off, their pages answer not
# found and no tool or route offers them (`Autolaunch.CoveredCalls.Deployment`).
covered_calls_on =
  case System.get_env("AUTOLAUNCH_COVERED_CALLS") do
    nil -> false
    "true" -> not migrating?
    _other -> raise "AUTOLAUNCH_COVERED_CALLS must be true or unset"
  end

if covered_calls_on do
  covered_calls_path =
    deployment_path.("AUTOLAUNCH_BASE_COVERED_CALLS_DEPLOYMENT") ||
      raise "AUTOLAUNCH_COVERED_CALLS=true needs AUTOLAUNCH_BASE_COVERED_CALLS_DEPLOYMENT"

  if is_nil(base_deployment) do
    raise "AUTOLAUNCH_COVERED_CALLS=true needs AUTOLAUNCH_BASE_DEPLOYMENT"
  end

  Autolaunch.CoveredCalls.Deployment.load!(covered_calls_path)

  config :autolaunch,
    covered_calls: :on,
    autolaunch_base_covered_calls_deployment: covered_calls_path
end

# Exposure is offered only on a site switched on with AUTOLAUNCH_EXPOSURE=true;
# then the description of its series is required, and it extends the Base
# description. Off, its page answers not found and no tool or route offers it
# (`Autolaunch.Exposure.Deployment`).
exposure_on =
  case System.get_env("AUTOLAUNCH_EXPOSURE") do
    nil -> false
    "true" -> not migrating?
    _other -> raise "AUTOLAUNCH_EXPOSURE must be true or unset"
  end

if exposure_on do
  exposure_path =
    deployment_path.("AUTOLAUNCH_BASE_EXPOSURE_DEPLOYMENT") ||
      raise "AUTOLAUNCH_EXPOSURE=true needs AUTOLAUNCH_BASE_EXPOSURE_DEPLOYMENT"

  if is_nil(base_deployment) do
    raise "AUTOLAUNCH_EXPOSURE=true needs AUTOLAUNCH_BASE_DEPLOYMENT"
  end

  Autolaunch.Exposure.Deployment.load!(exposure_path)

  config :autolaunch,
    exposure: :on,
    autolaunch_base_exposure_deployment: exposure_path
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

# ENS names and pictures are read from Ethereum mainnet through this endpoint:
# each sign-in's lookup (Autolaunch.Accounts.EnsIdentity) and Connect ENS.
if ethereum_read_rpc_url = System.get_env("ETHEREUM_READ_RPC_URL") do
  case URI.new(ethereum_read_rpc_url) do
    {:ok, %URI{scheme: "https", host: host}} when host not in [nil, ""] ->
      config :autolaunch, :ethereum_read_rpc_url, ethereum_read_rpc_url

    _invalid ->
      raise "ETHEREUM_READ_RPC_URL must be an https address"
  end
end

# The shared libraries read Base and Ethereum through the site's own nodes when it
# has them (Autolaunch.Chain.NodeClient), the same ones its launch reads and ENS use.
if config_env() == :prod and not migrating? do
  config :autolaunch, :source_commit, System.fetch_env!("SOURCE_COMMIT")

  node_overrides =
    for {chain_id, setting} <- [{8453, "BASE_READ_RPC_URL"}, {1, "ETHEREUM_READ_RPC_URL"}],
        node_url = System.get_env(setting),
        into: %{},
        do: {chain_id, node_url}

  config :autolaunch,
         :chain_nodes,
         Map.merge(Application.fetch_env!(:autolaunch, :chain_nodes), node_overrides)
end

if config_env() == :prod do
  config :autolaunch, :session_options, secure: true, http_only: true

  # One JSON object a line, which Fly Sentinel reads, carrying only the visit
  # fields (AutolaunchWeb.VisitLog). Release commands write the same shape.
  config :logger, :default_handler,
    formatter: LoggerJSON.Formatters.Basic.new(metadata: AutolaunchWeb.VisitLog.fields())

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

    # Fly's managed Prometheus scrapes the site health set here, over Fly's
    # private network (`fly.toml` `[metrics]`). Only `[http_service]` is public.
    config :autolaunch, :metrics_port, 9091

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
