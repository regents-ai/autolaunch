import Config

Code.require_file("env_local.exs", __DIR__)

env_or_local = fn key, default ->
  Autolaunch.ConfigEnvLocal.fetch(key, default)
end

test_database_url =
  env_or_local.("LOCAL_DATABASE_URL", "") ||
    env_or_local.("DATABASE_URL", "") ||
    env_or_local.("DATABASE_URL_UNPOOLED", "")

if is_binary(test_database_url) and String.trim(test_database_url) != "" do
  config :autolaunch, Autolaunch.Repo,
    url: test_database_url,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10
else
  config :autolaunch, Autolaunch.Repo,
    username:
      env_or_local.("DB_USER", env_or_local.("PGUSER", System.get_env("USER") || "postgres")),
    password: env_or_local.("DB_PASS", env_or_local.("PGPASSWORD", "")),
    hostname: env_or_local.("DB_HOST", env_or_local.("PGHOST", "localhost")),
    port: String.to_integer(env_or_local.("DB_PORT", env_or_local.("PGPORT", "5432"))),
    database: env_or_local.("DB_NAME", "autolaunch_test"),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10
end

config :autolaunch, AutolaunchWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4011],
  secret_key_base: "0wP3dZNju0aYGiE9XBJoTKcX9P8lWl9OCyD9iGYj2mTq4P7sVjJkJv9s7JvFh9uU",
  server: false

config :autolaunch, :privy,
  app_id: "test-app",
  verification_key: "test-key"

config :autolaunch, :siwa,
  internal_url: "http://localhost:4100",
  shared_secret: "autolaunch-test-shared-secret"

config :agent_world, :world_id,
  app_id: "app_test",
  action: "agentbook-registration",
  rp_id: "app_staging_test",
  signing_key: "0x59c6995e998f97a5a0044966f094538c5f6c75a5d9e7f0b6e6a0f9f5d4d17ce4",
  ttl_seconds: 300

config :agent_world, :networks, %{
  "world" => %{rpc_url: "https://world.example", relay_url: nil},
  "base" => %{rpc_url: "https://base.example", relay_url: nil},
  "base-sepolia" => %{rpc_url: "https://base-sepolia.example", relay_url: nil}
}

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
