import Config

browser_port = String.to_integer(System.get_env("PORT", "4050"))

# Several test servers can share one local PostgreSQL, which admits a fixed
# number of connections; a long-lived lab site asks for a small pool.
pool_size = String.to_integer(System.get_env("AUTOLAUNCH_DB_POOL_SIZE", "10"))

if pool_size < 1 do
  raise "AUTOLAUNCH_DB_POOL_SIZE must be a positive integer"
end

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# A local-lab site may take real Privy sign-ins. Then the production verifier
# checks each token pair against the configured public app id and public
# verification key (runtime.exs reads both), and the site is served at
# http://localhost:PORT, the loopback origin the Privy application admits.
# Nothing else in the test environment changes: the fixture verifier stays
# in force for ExUnit and for the Playwright server.
lab_auth = System.get_env("AUTOLAUNCH_LAB_AUTH")

unless lab_auth in [nil, "", "privy"] do
  raise "AUTOLAUNCH_LAB_AUTH must be privy or unset"
end

lab_privy? = lab_auth == "privy"

# Explicit real sign-in never falls back to the fixture verifier: asked for
# without a lab config, the boot stops here instead of starting a site whose
# notice would promise Privy while its verifier accepts fixture tokens.
if lab_privy? and System.get_env("AUTOLAUNCH_LAB_CONFIG") in [nil, ""] do
  raise "AUTOLAUNCH_LAB_AUTH=privy needs AUTOLAUNCH_LAB_CONFIG"
end

# We don't run a server during test. The Playwright suite asks for one by
# setting AUTOLAUNCH_BROWSER_TEST.
config :autolaunch, AutolaunchWeb.Endpoint,
  url: [host: if(lab_privy?, do: "localhost", else: "127.0.0.1"), port: browser_port],
  http: [ip: {127, 0, 0, 1}, port: browser_port],
  check_origin:
    ["http://127.0.0.1:#{browser_port}"] ++
      if(lab_privy?, do: ["http://localhost:#{browser_port}"], else: []),
  secret_key_base: "dE279MxKIvZfbwjSpb4wz+TRnO8doR91/kD/kxxXO9FIFvDeVF132xDj2X5J2/x5",
  server: System.get_env("AUTOLAUNCH_BROWSER_TEST") == "1"

config :autolaunch, Autolaunch.Repo,
  username: System.get_env("USER"),
  password: nil,
  hostname: "127.0.0.1",
  port: 5432,
  database: "autolaunch#{System.get_env("MIX_TEST_PARTITION")}_test",
  pool_size: pool_size,
  # A case that sends two callers at one row shares one sandboxed connection
  # between them, so the second caller waits while the first one holds it. The
  # sandbox drops a waiting caller once it has waited longer than twice
  # :queue_target, and it looks for callers to drop once every :queue_interval,
  # which is one second. At the default target of 50ms that abandons a caller
  # after a tenth of a second, and the case then fails on a checkout error
  # rather than on anything it set out to prove. The 1_000ms below lets a
  # caller wait two seconds instead.
  queue_target: 1_000,
  # The Playwright server must commit drafts and sessions; ExUnit keeps the
  # sandbox so ordinary cases stay isolated.
  pool:
    if(System.get_env("AUTOLAUNCH_BROWSER_TEST") == "1",
      do: DBConnection.ConnectionPool,
      else: Ecto.Adapters.SQL.Sandbox
    )

config :ash, :missed_notifications, :ignore

config :autolaunch,
       :privy_verifier,
       if(lab_privy?, do: Autolaunch.Privy, else: Autolaunch.TestPrivyVerifier)

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
# A server given a local lab config skips these three: launch and bid then
# resolve to their lab clients and answer from the fork, subject-wallet
# preparation stays unavailable (no lab client exists for it), and the
# treasury fixture selected above remains in force.
if System.get_env("AUTOLAUNCH_BROWSER_TEST") == "1" and
     System.get_env("AUTOLAUNCH_LAB_CONFIG") in [nil, ""] do
  config :autolaunch,
         :autolaunch_subject_wallet_chain_client,
         Autolaunch.TestAutolaunchSubjectWalletChainClient

  config :autolaunch,
         :autolaunch_launch_chain_client,
         Autolaunch.TestAutolaunchLaunchChainClient

  config :autolaunch,
         :autolaunch_treasury_chain_client,
         Autolaunch.TestAutolaunchTreasuryChainClient
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
