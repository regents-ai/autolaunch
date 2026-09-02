defmodule AutolaunchWeb.Router do
  use AutolaunchWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :enforce_session_authority
    plug :fetch_live_flash
    plug :put_root_layout, html: {AutolaunchWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  def enforce_session_authority(conn, _opts) do
    AutolaunchWeb.PrivySessionController.enforce_authority(conn)
  end

  scope "/", AutolaunchWeb do
    # The platform health check answers before sessions, flash or CSRF.
    get "/healthz", HealthController, :show
  end

  scope "/", AutolaunchWeb do
    pipe_through :browser

    live "/", HomeLive, :home

    get "/auth/csrf", PrivySessionController, :csrf
    post "/auth/privy/session", PrivySessionController, :create
    get "/auth/session", PrivySessionController, :show
    delete "/auth/privy/session", PrivySessionController, :delete
    post "/auth/x/connections/:role", XOAuthController, :create
    delete "/auth/x/connections/:role", XOAuthController, :delete
    delete "/auth/x/connections/:role/attempt", XOAuthController, :cancel
    get "/auth/x/callback", XOAuthController, :callback, log: false

    live_session :product_shell,
      session: {AutolaunchWeb.Live.Session, :render_context, []},
      on_mount: [{AutolaunchWeb.Live.Session, :load_human}] do
      live "/portfolio", PortfolioLive, :portfolio
    end
  end
end
