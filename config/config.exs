# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

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
  ash_domains: [Autolaunch.Accounts],
  ecto_repos: [Autolaunch.Repo],
  generators: [timestamp_type: :utc_datetime]

config :autolaunch, :base_read_rpc_url, "https://base-rpc.publicnode.com"

config :autolaunch, :session_bootstrap_rate_limit, limit: 30, window_seconds: 300

config :autolaunch, :session_options,
  store: :cookie,
  key: "_autolaunch_key",
  signing_salt: "hqjc/6fr",
  same_site: "Lax",
  secure: false,
  http_only: true

# Configure the endpoint
config :autolaunch, AutolaunchWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AutolaunchWeb.ErrorHTML, json: AutolaunchWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Autolaunch.PubSub,
  live_view: [signing_salt: "HgYkLXOk"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  autolaunch: [
    args:
      ~w(js/app.ts --bundle --format=esm --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
