import Config

config :autolaunch,
  runtime_env: config_env(),
  ecto_repos: [Autolaunch.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

config :autolaunch, AutolaunchWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AutolaunchWeb.ErrorHTML, json: AutolaunchWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Autolaunch.PubSub,
  live_view: [signing_salt: "DRIHbY4r"]

config :autolaunch, :launch,
  chain_id: 84_532,
  network: "base-sepolia",
  allow_unverified_owner: false,
  deploy_script_target: ""

config :autolaunch, Autolaunch.Xmtp,
  rooms: [
    %{
      key: "autolaunch_wire",
      name: "Autolaunch Wire",
      description: "The shared Autolaunch chat room.",
      app_data: "autolaunch-wire",
      agent_private_key: nil,
      moderator_wallets: [],
      capacity: 200,
      presence_timeout_ms: :timer.minutes(2),
      presence_check_interval_ms: :timer.seconds(30),
      policy_options: %{
        allowed_kinds: [:human, :agent],
        required_claims: %{}
      }
    }
  ]

config :autolaunch, :regent_staking,
  chain_id: 8_453,
  chain_label: "Base",
  rpc_url: "",
  contract_address: ""

config :esbuild,
  version: "0.25.4",
  autolaunch: [
    args:
      ~w(js/app.ts --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  autolaunch: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
