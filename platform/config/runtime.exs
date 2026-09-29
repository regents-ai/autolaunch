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

autolaunch_lab_path = System.get_env("AUTOLAUNCH_LAB_CONFIG")

autolaunch_lab =
  case {config_env(), autolaunch_lab_path} do
    {_env, nil} ->
      nil

    {_env, ""} ->
      nil

    {:prod, _path} ->
      raise "AUTOLAUNCH_LAB_CONFIG is development/test only"

    {env, path} when env in [:dev, :test] ->
      Autolaunch.Lab.load!(path)
  end

config :autolaunch, :autolaunch_lab_enabled, not is_nil(autolaunch_lab)
config :autolaunch, :autolaunch_lab_config_path, autolaunch_lab && autolaunch_lab.path

if autolaunch_lab do
  config :autolaunch,
         :autolaunch_lab_run_id,
         System.fetch_env!("AUTOLAUNCH_ACCEPTANCE_RUN_ID")
end

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

# The Base log ledger reads its own dedicated endpoint, separate from the
# simple-read RPC. The test environment owns this setting outright so a shell
# that exports one cannot start an indexer under a test run. When a lab config
# path is set the ledger stays off, as source runtime.exs:120-123.
lab_configured? =
  case System.get_env("AUTOLAUNCH_LAB_CONFIG") do
    value when is_binary(value) and value != "" -> true
    _missing -> false
  end

if lab_configured? do
  config :autolaunch, :autolaunch_indexer_rpc_url, nil
else
  config :autolaunch,
         :autolaunch_indexer_rpc_url,
         if(config_env() == :test, do: nil, else: System.get_env("AUTOLAUNCH_INDEXER_RPC_URL"))
end

if database_config do
  config :autolaunch, :database_startup_enabled, true
  config :autolaunch, Autolaunch.Repo, database_config
end

if config_env() == :prod do
  # The site reads one canonical `safe` Base block through this endpoint.
  # Development has a default in `config.exs`; production must say which
  # endpoint it trusts, so a missing value stops the boot instead of quietly
  # reading a public one.
  config :autolaunch, :base_read_rpc_url, System.fetch_env!("BASE_READ_RPC_URL")

  config :autolaunch, :session_options, secure: true, http_only: true

  unless migrating? do
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
