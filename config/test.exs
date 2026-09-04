import Config
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# We don't run a server during test. The Playwright suite asks for one by
# setting AUTOLAUNCH_BROWSER_TEST.
config :autolaunch, AutolaunchWeb.Endpoint,
  url: [host: "127.0.0.1", port: 4050],
  http: [ip: {127, 0, 0, 1}, port: 4050],
  check_origin: ["http://127.0.0.1:4050"],
  secret_key_base: "dE279MxKIvZfbwjSpb4wz+TRnO8doR91/kD/kxxXO9FIFvDeVF132xDj2X5J2/x5",
  server: System.get_env("AUTOLAUNCH_BROWSER_TEST") == "1"

config :autolaunch, Autolaunch.Repo,
  username: System.get_env("USER"),
  password: nil,
  hostname: "127.0.0.1",
  port: 5432,
  database: "autolaunch#{System.get_env("MIX_TEST_PARTITION")}_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  # A case that sends two callers at one row shares one sandboxed connection
  # between them, so the second caller waits while the first one holds it. The
  # sandbox drops a waiting caller once it has waited longer than twice
  # :queue_target, and it looks for callers to drop once every :queue_interval,
  # which is one second. At the default target of 50ms that abandons a caller
  # after a tenth of a second, and the case then fails on a checkout error
  # rather than on anything it set out to prove. The 1_000ms below lets a
  # caller wait two seconds instead.
  queue_target: 1_000

config :ash, :missed_notifications, :ignore

config :autolaunch, :privy_verifier, Autolaunch.TestPrivyVerifier

config :autolaunch,
       :autolaunch_treasury_chain_client,
       Autolaunch.TestAutolaunchTreasuryChainClient

config :autolaunch, :database_startup_enabled, true

# The Base log ledger never runs under test: the tests drive its handler
# directly against a fake endpoint, and nothing in the shell can turn it on.
config :autolaunch, :autolaunch_indexer_rpc_url, nil

config :autolaunch,
       :autolaunch_indexer_http_client,
       Autolaunch.TestAutolaunchIndexerChainClient

# The subject-wallet and launch browser proofs need a Base answer without a
# provider, a wallet or a chain call. Ordinary ExUnit cases install and restore
# these clients themselves, so only the Playwright server process selects them.
if System.get_env("AUTOLAUNCH_BROWSER_TEST") == "1" do
  config :autolaunch,
         :autolaunch_subject_wallet_chain_client,
         Autolaunch.TestAutolaunchSubjectWalletChainClient

  config :autolaunch,
         :autolaunch_launch_chain_client,
         Autolaunch.TestAutolaunchLaunchChainClient
end

# Every test case here reaches one node holding one anonymous bootstrap budget
# for the loopback address they all share, so the release-sized allowance is
# raised rather than let unrelated cases spend one another's. The focused
# controller tests restore the release 30/300 themselves.
config :autolaunch, :session_bootstrap_rate_limit, limit: 100_000, window_seconds: 300

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
