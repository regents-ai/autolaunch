defmodule AutolaunchWeb.Router do
  use AutolaunchWeb, :router

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

  scope "/", AutolaunchWeb do
    pipe_through :browser

    live_session :autolaunch,
      on_mount: [{AutolaunchWeb.LiveAuth, :current_human}] do
      live "/", AuctionGuideLive, :index
      live "/how-auctions-work", AuctionGuideLive, :index
      live "/launch", LaunchLive, :index
      live "/agentbook", AgentbookLive, :index
      live "/ens-link", EnsLinkLive, :index
      live "/auctions", AuctionsLive, :index
      live "/auctions/:id", AuctionLive, :show
      live "/positions", PositionsLive, :index
    end
  end

  scope "/", AutolaunchWeb do
    pipe_through :api

    get "/health", HealthController, :show
    post "/v1/agent/siwa/nonce", AgentSiwaController, :nonce
    post "/v1/agent/siwa/verify", AgentSiwaController, :verify
  end

  scope "/api/auth", AutolaunchWeb do
    pipe_through :session_api

    post "/privy/session", PrivySessionController, :create
    delete "/privy/session", PrivySessionController, :delete
  end

  scope "/api", AutolaunchWeb.Api do
    pipe_through :api

    post "/agentbook/sessions", AgentbookController, :create
    get "/agentbook/sessions/:id", AgentbookController, :show
    post "/agentbook/sessions/:id/submit", AgentbookController, :submit
    get "/agentbook/lookup", AgentbookController, :lookup
    post "/agentbook/verify", AgentbookController, :verify
  end

  scope "/api", AutolaunchWeb.Api do
    pipe_through :session_api

    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show
    get "/agents/:id/readiness", AgentController, :readiness

    post "/launch/preview", LaunchController, :preview
    post "/launch/jobs", LaunchController, :create_job
    get "/launch/jobs/:id", LaunchController, :show_job

    get "/auctions", AuctionController, :index
    get "/auctions/:id", AuctionController, :show
    post "/auctions/:id/bid_quote", AuctionController, :bid_quote
    post "/auctions/:id/bids", AuctionController, :create_bid

    get "/me/bids", MeController, :bids

    post "/bids/:id/exit", BidController, :exit
    post "/bids/:id/claim", BidController, :claim

    post "/ens/link/plan", EnsLinkController, :plan
    post "/ens/link/prepare-ensip25", EnsLinkController, :prepare_ensip25
    post "/ens/link/prepare-erc8004", EnsLinkController, :prepare_erc8004
    post "/ens/link/prepare-bidirectional", EnsLinkController, :prepare_bidirectional
  end

  if Application.compile_env(:autolaunch, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AutolaunchWeb.Telemetry
    end
  end
end
