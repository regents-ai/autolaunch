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
  chain_id: 1,
  network: "ethereum-mainnet",
  allow_unverified_owner: false,
  deploy_script_target: ""

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
import_config "runtime.exs"
