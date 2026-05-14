defmodule AutolaunchWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :autolaunch

  @base_session_options [
    store: :cookie,
    key: "_autolaunch_key",
    signing_salt: "f6n9rGqM",
    same_site: "Lax"
  ]

  @runtime_env Application.compile_env(:autolaunch, :runtime_env, :dev)
  @session_options if @runtime_env == :prod,
                     do: Keyword.put(@base_session_options, :secure, true),
                     else: @base_session_options

  def session_options(runtime_env \\ @runtime_env) do
    maybe_secure_session(@base_session_options, runtime_env)
  end

  defp maybe_secure_session(options, :prod), do: Keyword.put(options, :secure, true)
  defp maybe_secure_session(options, _runtime_env), do: options

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :autolaunch,
    gzip: not code_reloading?,
    only: AutolaunchWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :autolaunch
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {AutolaunchWeb.RawBodyReader, :read_body, []}

  plug Sentry.PlugContext

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug AutolaunchWeb.Router
end
