import Config

config :autolaunch, AutolaunchWeb.Endpoint,
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "w9CoAZ94M4ppYt4s7hjMNiVqTNorV6gX2cA8QiAUvM9OuJv6tfX7j5O5F2NiCp3Z",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:autolaunch, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:autolaunch, ~w(--watch)]}
  ]

config :autolaunch, AutolaunchWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"priv/gettext/.*\.po$"E,
      ~r"lib/autolaunch_web/router\.ex$"E,
      ~r"lib/autolaunch_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

config :autolaunch, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
