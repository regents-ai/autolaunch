defmodule AutolaunchWeb.Router do
  use AutolaunchWeb, :router
  require AutolaunchWeb.ApiRoutes

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AutolaunchWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AutolaunchWeb.Plugs.LoadCurrentHuman
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :session_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :put_secure_browser_headers
    plug AutolaunchWeb.Plugs.LoadCurrentHuman
  end

  pipeline :browser_session_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AutolaunchWeb.Plugs.LoadCurrentHuman
  end

  pipeline :agent_api do
    plug :accepts, ["json"]
    plug AutolaunchWeb.Plugs.RequireAgentSiwa
  end

  scope "/", AutolaunchWeb do
    pipe_through :browser

    live_session :autolaunch,
      on_mount: [{AutolaunchWeb.LiveAuth, :current_human}] do
      live "/", HomeLive, :index
      live "/how-auctions-work", AuctionGuideLive, :index
      live "/launch", LaunchLive, :index
      live "/launch-via-agent", LaunchLive, :agent
      live "/agentbook", AgentbookLive, :index
      live "/ens-link", EnsLinkLive, :index
      live "/x-link", XLinkLive, :index
      live "/terms", TermsLive, :index
      live "/privacy", PrivacyLive, :index
      live "/auctions", AuctionsLive, :index
      live "/auction-returns", AuctionReturnsLive, :index
      live "/auctions/:id", AuctionLive, :show
      live "/profile", ProfileLive, :index
      live "/positions", PositionsLive, :index
      live "/regent-staking", RegentStakingLive, :index
      live "/contracts", ContractsLive, :index
      live "/status", StatusLive, :index
      live "/subjects/:id", SubjectLive, :show
    end
  end

  scope "/", AutolaunchWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/v1/auth", AutolaunchWeb do
    pipe_through :browser_session_api

    get "/privy/csrf", PrivySessionController, :csrf
    post "/privy/session", PrivySessionController, :create
    post "/privy/xmtp/complete", PrivySessionController, :complete_xmtp
    get "/privy/profile", PrivySessionController, :show
    delete "/privy/session", PrivySessionController, :delete
  end

  scope "/v1/auth/agent", AutolaunchWeb do
    pipe_through :browser_session_api

    get "/session", AgentSessionController, :show
    delete "/session", AgentSessionController, :delete
  end

  scope "/v1/auth/agent", AutolaunchWeb do
    pipe_through [:browser_session_api, :agent_api]

    post "/session", AgentSessionController, :create
  end

  scope "/v1/app", AutolaunchWeb.Api do
    pipe_through :api

    post "/agentbook/sessions", AgentbookController, :create
    get "/agentbook/sessions/:id", AgentbookController, :show
    post "/agentbook/sessions/:id/submit", AgentbookController, :submit
    get "/agentbook/lookup", AgentbookController, :lookup
    post "/agentbook/verify", AgentbookController, :verify
  end

  scope "/v1/app", AutolaunchWeb.Api do
    pipe_through :session_api

    AutolaunchWeb.ApiRoutes.product_api_routes(
      include_app_staking_prepare?: true,
      include_human_browser_routes?: true
    )
  end

  scope "/v1/agent", AutolaunchWeb.Api do
    pipe_through :agent_api

    AutolaunchWeb.ApiRoutes.product_api_routes()
  end

  if Application.compile_env(:autolaunch, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AutolaunchWeb.Telemetry
    end
  end
end
