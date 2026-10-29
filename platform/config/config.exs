# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash_oban, pro?: false

# Background jobs: the launch listing's and the auction finisher's
# minute-by-minute checks, the stocks' half-hourly volume reads and the
# five-minute read of the stocks each launchpad admits, one job at a time on
# each of those queues; the chain readings, one job for each listed auction's
# bids, each listed token's trades and each chain's ledger, four at a time
# (Autolaunch.ChainWatch makes sure each has its job every minute); the
# default queue's quick jobs, the daily
# clearing of saved errors (Autolaunch.ErrorPruner) and the choice of stocks
# to read; and Regent Credits' minute-by-minute checks of purchases and Base
# deposits (application.ex adds the RegentCredits domain). The finishing queue
# stays paused unless the site has the finisher switched on (runtime.exs); its
# jobs are unique, so a paused queue holds at most one of each.
# The web connection may go through PgBouncer, which cannot hold a LISTEN, so
# jobs are announced between processes instead of through PostgreSQL.
# The commit the running site was built from, named by /healthz. A release
# image carries it as SOURCE_COMMIT (runtime.exs); a local build is "local".
config :autolaunch, :source_commit, "local"

config :autolaunch, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.PG,
  repo: Autolaunch.Repo,
  prefix: "autolaunch_app",
  queues: [
    auction_finishing: [limit: 1, paused: true],
    chain: 4,
    launch_listing: 1,
    outside_calls: 3,
    stock_volume: 1,
    stock_admissions: 1,
    share_videos: 1,
    default: 1,
    regent_credits: 3
  ],
  cron: [crontab: [{"* * * * *", Autolaunch.ChainWatch}, {"17 4 * * *", Autolaunch.ErrorPruner}]],
  pruner: [max_age: {7, :days}],
  # A job still executing after this long is taken for one whose machine
  # stopped. It sits above the volume reads' fifteen-minute limit, so a read
  # still running is never taken over; a finishing check orphaned by a stopped
  # machine holds that launch's next check back until then.
  lifeline: [rescue_after: {20, :minutes}]

# `allowed` is what an agent may do here in each status, as signed
# GET /api/agents/v1/whoami tells it: true to the agent routes and the agent
# guide (agents.md), so change it with them.
config :regent_agents,
  repo: Autolaunch.Repo,
  pubsub: Autolaunch.PubSub,
  notifications: Autolaunch.Notifications,
  account: {Autolaunch.Agents, :paired_account},
  allowed: %{
    "not_paired" => [
      "Read public auctions, tokens, treasury reports and bid estimates.",
      "Check your status here at any time.",
      "Pair with the code your person makes with Pair New Agent on their Account page."
    ],
    "paired" => [
      "Read public auctions, tokens, treasury reports and bid estimates.",
      "Check your status here at any time, and check in for your person.",
      "Read your person's Revstake and Memestock drafts, and save their text while launches are open.",
      "Read your person's bids and tokens.",
      "Read your person's Credits and Points.",
      "Signing with a wallet, launching, bidding, trading, staking and claiming stay with your person."
    ]
  },
  ash_domains: [RegentAgents],
  siwa: [url: "https://siwa.regents.sh", audience: "autolaunch"]

config :regent_credits,
  repo: Autolaunch.Repo,
  pubsub: Autolaunch.PubSub,
  notifications: Autolaunch.Notifications,
  ash_domains: [RegentCredits],
  admins: [],
  agent_grants_enabled: false,
  chain_client: Autolaunch.Chain.NodeClient,
  chains: %{
    base: %{chain_id: 8453, name: "Base", rpc_url: "https://mainnet.base.org"},
    ethereum: %{chain_id: 1, name: "Ethereum", rpc_url: "https://ethereum-rpc.publicnode.com"}
  }

config :ex_money,
  custom_currencies: [{:XRC, name: "Credits", digits: 6}],
  auto_start_exchange_rate_service: false

config :regent_points,
  repo: Autolaunch.Repo,
  pubsub: Autolaunch.PubSub,
  accounts: Autolaunch.Points.Accounts,
  chain_client: Autolaunch.Chain.NodeClient,
  ash_domains: [RegentPoints],
  program_id: "regents-points-v1",
  starts_at: nil,
  approved_rules: [],
  adapters: %{}

config :regent_identity, repo: Autolaunch.Repo, ash_domains: [RegentIdentity]

# Every Autolaunch table lives in this schema, in every environment.
config :autolaunch, Autolaunch.Repo,
  default_prefix: "autolaunch_app",
  migration_default_prefix: "autolaunch_app"

# Count codepoints consistently with PostgreSQL; a grapheme may contain unbounded
# combining marks (CVE-2026-82752). Required by Ash 3.33 and shared identity resources.
config :ash, default_string_length_count: :codepoints

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  # An unauthorized read answers with Ash.Error.Forbidden rather than an empty
  # result, so a refusal can never be mistaken for an absent row.
  policies: [no_filter_static_forbidden_reads?: true],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

# Zoned Stocks start times resolve through the bundled IANA table; nothing is
# fetched at runtime.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :autolaunch,
  ash_domains: [
    Autolaunch.Accounts,
    Autolaunch,
    Autolaunch.Points,
    Autolaunch.CoveredCalls,
    Autolaunch.Exposure,
    Autolaunch.Agents
  ],
  ecto_repos: [Autolaunch.Repo],
  generators: [timestamp_type: :utc_datetime]

config :autolaunch, :base_read_rpc_url, "https://base-rpc.publicnode.com"

# The node the shared libraries read each chain through, by chain id
# (Autolaunch.Chain.NodeClient): the Points bonus reads Base. A wallet adds a
# chain with its public address; this one never reaches the browser.
config :autolaunch, :chain_nodes, %{
  8453 => "https://mainnet.base.org",
  1 => "https://ethereum-rpc.publicnode.com"
}

# Robinhood Chain mainnet, read for the stock prices the create page shows.
config :autolaunch, :robinhood_read_rpc_url, "https://rpc.mainnet.chain.robinhood.com"
config :autolaunch, :autolaunch_indexer_chains, []

# Who reads a chain again when a person's action may have changed it
# (`Autolaunch.ChainRefresh`).
config :autolaunch, Autolaunch.ChainRefresh,
  readers: [
    Autolaunch.ChainHead,
    Autolaunch.AuctionMarket,
    Autolaunch.Robinhood.Discovery,
    Autolaunch.AuctionActivity,
    Autolaunch.TokenTrades,
    Autolaunch.Indexer.ReadChain,
    Autolaunch.LaunchDiscovery.DiscoverMemestock,
    Autolaunch.RegentFacts,
    Autolaunch.CoveredCalls.Book
  ]

# How long each server keeps a chain's saved stocks before reading them again;
# 0 keeps nothing.
config :autolaunch, :stock_list_kept_ms, 60_000

config :autolaunch, :session_bootstrap_rate_limit, limit: 30, window_seconds: 300

# How many bytes of made share videos the site saves; past it a video is still
# made, handed over once and not saved (AutolaunchWeb.ShareVideo.Render).
config :autolaunch, :share_video_saved_bytes, 5_000_000_000

# How often one account's wallet figures may be read from the chain, and how
# often it may report a Credits purchase, each window (Autolaunch.Limits).
config :autolaunch, :limits,
  wallet_read: [limit: 30, window_seconds: 60],
  credits_report: [limit: 120, window_seconds: 60]

# The API and health check budgets key on the direct peer. Production turns on
# Fly's client header.
config :autolaunch, :behind_fly_proxy, false

# The cookie lasts as long as a sign-in does (`Autolaunch.Accounts.SessionAuthority`).
config :autolaunch, :session_options,
  store: :cookie,
  key: "_autolaunch_key",
  signing_salt: "hqjc/6fr",
  max_age: 30 * 86_400,
  same_site: "Lax",
  secure: false,
  http_only: true

# Configure the endpoint
config :autolaunch, AutolaunchWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [
      html: AutolaunchWeb.ErrorHTML,
      json: AutolaunchWeb.ErrorJSON,
      md: AutolaunchWeb.ErrorMD
    ],
    layout: false
  ],
  pubsub_server: Autolaunch.PubSub,
  live_view: [signing_salt: "HgYkLXOk"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  autolaunch: [
    args:
      ~w(js/app.ts js/privy_bridge.tsx --bundle --splitting --format=esm --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ],
  # Covered calls' styles, built outside priv/static so nothing serves them while
  # covered calls are off (AutolaunchWeb.CoveredCallsController.stylesheet/2).
  covered_calls: [
    args:
      ~w(css/pages/covered_calls.css --bundle --outdir=../priv/covered_calls --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ],
  # Exposure's styles, built outside priv/static so nothing serves them while
  # Exposure is off (AutolaunchWeb.ExposureController.stylesheet/2).
  exposure: [
    args:
      ~w(css/pages/exposure.css --bundle --outdir=../priv/exposure --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ]

# The engine's own measurements (memory, run queues, process counts), taken every
# 10 seconds by telemetry_poller's default poller and exported as `vm.*` metrics.
config :telemetry_poller, :default, period: 10_000

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :visit, :actor, :surface, :event]

# Failed requests, pages and jobs are saved in the site's own schema and shown
# to Credits admins at /admin/errors. Only server faults are saved
# (Autolaunch.ErrorIgnorer), only where each one happened is kept
# (Autolaunch.ErrorFilter), and Autolaunch.ErrorPruner clears each one a week
# after it was last seen.
config :error_tracker,
  repo: Autolaunch.Repo,
  otp_app: :autolaunch,
  prefix: "autolaunch_app",
  ignorer: Autolaunch.ErrorIgnorer,
  filter: Autolaunch.ErrorFilter

# The Claude connector's sign-in, through the person's verified account
# (Autolaunch.OAuth). The identity permission lets the app pair with the account
# and check in; the agent permission lets it then work here as that paired
# agent. config/runtime.exs switches it on and sets its issuer and resource from
# the site's own address. Lifetimes are the library's, not set here: a Bearer
# token lives at most an hour and a refresh token 30 days (RegentOAuth.configure/1).
config :autolaunch, Autolaunch.OAuth,
  brand: "autolaunch",
  scope: "regent.identity.manage",
  permission_description:
    "pair with your account using a code you give it, and check in so you see it is active",
  additional_scopes: %{
    "autolaunch.agent" =>
      "work here as the agent you paired, with the same rights as any agent you pair"
  },
  consent_note:
    "This connection works here only as the agent you pair it with, with that agent's rights. Every app you connect here works as that same agent. It cannot bid, launch, trade, stake or change your wallets."

# The connector's identity tools (RegentMCPAgents): which site's signers they use
# at the sign-in service, and the words a refused tool call ends with.
# config/runtime.exs switches them on with the connector and gives the key.
config :regent_mcp_agents, :config,
  audience: "autolaunch",
  refusal:
    "Call get_identity to see where this connection stands. Not paired: ask your person for a new code from Pair New Agent on their Account page. Asked to connect: your person connects this app to Autolaunch again."

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Private signed inputs must not be included in Phoenix request parameter logs.
config :phoenix, :filter_parameters, [
  "password",
  "token",
  "secret",
  "code",
  "proof",
  "name",
  "description",
  "website",
  "telegram",
  "discord",
  "other_link",
  "body"
]
