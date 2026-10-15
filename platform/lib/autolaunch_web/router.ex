defmodule AutolaunchWeb.Router do
  use AutolaunchWeb, :router
  use ErrorTracker.Web, :router

  alias AutolaunchWeb.ContentSecurityPolicy

  # Format negotiation only; every scope also runs :browser_session for headers.
  # sobelow_skip ["Config.Headers"]
  pipeline :browser do
    plug :accepts, ["html"]
  end

  # Format negotiation only; every scope also runs :browser_session for headers.
  # sobelow_skip ["Config.Headers"]
  pipeline :browser_auth do
    plug :accepts, ["html", "json"]
  end

  # The policy is built by ContentSecurityPolicy; Sobelow cannot evaluate its value.
  # sobelow_skip ["Config.CSP"]
  pipeline :browser_session do
    plug :fetch_session
    plug :enforce_session_authority
    plug :fetch_live_flash
    plug :put_root_layout, html: {AutolaunchWeb.Layouts, :root}
    plug AutolaunchWeb.Plugs.Theme
    plug AutolaunchWeb.Plugs.Panels
    plug :protect_from_forgery

    # Every page can start sign-in from its top bar. Browser agents may use the
    # tools the pages register, from this site only.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.sign_in(),
      "permissions-policy" => "tools=(self)"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The signed-in person's own session API; never agent authority.
  pipeline :session_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :enforce_session_authority
    plug :protect_from_forgery
  end

  # The saved errors: Credits admins only. Anyone else gets the not-found page under
  # the reading policy; an admin's page replaces it with one carrying this
  # request's nonce (AutolaunchWeb.ErrorsAdmin).
  # The policy is built by ContentSecurityPolicy; Sobelow cannot evaluate its value.
  # sobelow_skip ["Config.CSP"]
  pipeline :errors_admin do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :enforce_session_authority
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.reading(),
      "referrer-policy" => "no-referrer"
    }

    plug AutolaunchWeb.ErrorsAdmin
  end

  pipeline :motion_lab do
    plug :admit_motion_lab
  end

  def admit_motion_lab(conn, _opts), do: AutolaunchWeb.Showcase.admit(conn, :motion_lab)

  def enforce_session_authority(conn, _opts),
    do: AutolaunchWeb.PrivySessionController.enforce_authority(conn)

  scope "/", AutolaunchWeb do
    # The platform health check answers before sessions, flash or CSRF.
    get "/healthz", HealthController, :show

    # The pictures shared auction and token links show, read by sites without
    # a session.
    get "/auctions/:symbol/:tail/share.png", ShareCardController, :auction
    get "/tokens/:symbol/:tail/share.png", ShareCardController, :token

    # Addresses the site gave auctions and tokens before they were named by
    # ticker. Links to them were shared, so each moves permanently to the
    # record's page or picture today. This is the only place they are read.
    get "/auctions/:auction_id/share.png", OldLinkController, :base_auction_image
    get "/robinhood/auctions/:auction/share.png", OldLinkController, :robinhood_auction_image
    get "/auctions/:auction_id", OldLinkController, :base_auction
    get "/robinhood/auctions/:auction", OldLinkController, :robinhood_auction
    get "/tokens/:token_id", OldLinkController, :base_token
    get "/robinhood/tokens/:token", OldLinkController, :robinhood_token

    get "/llms.txt", PublicPagesController, :agent_guide
    get "/agents.md", PublicPagesController, :signed_agent_guide
    get "/skill.md", PublicPagesController, :signed_agent_guide
    get "/sitemap.xml", PublicPagesController, :sitemap
    get "/openapi.json", PublicPagesController, :openapi
    get "/robots.txt", PublicPagesController, :robots
    get "/capabilities", PublicPagesController, :capabilities
    get "/.well-known/security.txt", PublicPagesController, :security
    get "/.well-known/api-catalog", PublicPagesController, :api_catalog

    # The developer guide's earlier address; links to it were shared.
    get "/developers", PublicPagesController, :developers
  end

  scope "/api/agents" do
    pipe_through :api
    forward "/v1", RegentAgents.HTTP
  end

  scope "/api/agent/v1", AutolaunchWeb do
    pipe_through :api
    get "/drafts/:kind", AgentAccountController, :draft
    patch "/drafts/:kind", AgentAccountController, :save_draft
    get "/positions", AgentAccountController, :positions
    get "/account/balances", AgentAccountController, :balances
    post "/account/credits/history", AgentAccountController, :history
    get "/account/points", AgentAccountController, :points
  end

  scope "/api/v1" do
    pipe_through :api
    forward "/profile", RegentIdentity.HTTP, otp_app: :autolaunch
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through :api

    get "/auctions", AuctionController, :index
    get "/auctions/:id", AuctionController, :show
    post "/auctions/:id/bid-quote", AuctionController, :bid_quote
    get "/tokens", TokenController, :index
    get "/tokens/:id", TokenController, :show
    get "/treasury-security/:address", TreasuryController, :show
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through :session_api

    get "/me/positions", MyPositionsController, :show
  end

  scope "/", AutolaunchWeb do
    pipe_through [:browser_auth, :browser_session]

    get "/auth/csrf", PrivySessionController, :csrf
    post "/auth/privy/session", PrivySessionController, :create
    get "/auth/session", PrivySessionController, :show
    delete "/auth/privy/session", PrivySessionController, :delete
    post "/auth/x/connections/:role", XOAuthController, :create
    delete "/auth/x/connections/:role", XOAuthController, :delete
    delete "/auth/x/connections/:role/attempt", XOAuthController, :cancel
  end

  scope "/", AutolaunchWeb do
    pipe_through [:browser, :browser_session]

    live_session :public_root,
      session: {AutolaunchWeb.Live.Session, :render_context, []},
      on_mount: [
        {AutolaunchWeb.Live.Session, :public_human},
        {AutolaunchWeb.Live.Credits, :credits}
      ] do
      live "/", HomeLive, :home
    end

    get "/upcoming", PublicPagesController, :upcoming_stocks
    get "/docs", PublicPagesController, :show
    get "/about", PublicPagesController, :show
    get "/contact", PublicPagesController, :show
    get "/privacy", PublicPagesController, :show
    get "/terms", PublicPagesController, :show

    get "/blog", BlogController, :index
    get "/blog/:slug", BlogController, :show

    get "/auth/x/callback", XOAuthController, :callback, log: false

    live_session :product_shell,
      session: {AutolaunchWeb.Live.Session, :render_context, []},
      on_mount: [
        {AutolaunchWeb.Live.Session, :load_human},
        {AutolaunchWeb.Live.Credits, :credits}
      ] do
      live "/create", StocksCreateLive, :create
      live "/create/revstake", CreateLive, :create
      live "/auctions", AuctionsLive, :index
      live "/auctions/:symbol/:tail", MarketPageLive, :auction
      live "/tokens", TokensLive, :index
      live "/tokens/:symbol/:tail", MarketPageLive, :token
      live "/upcoming-stocks", UpcomingLive, :show
      live "/how-it-works", HowItWorksLive, :show
      live "/portfolio", PortfolioLive, :portfolio
      live "/portfolio/bids/:id", BidLive, :bid
      live "/account", AccountLive, :account
      live "/account/points", PointsLive, :points
      live "/regent", RegentLive, :regent
      live "/convert", ConvertLive, :index
    end
  end

  # The motion lab, unless the showcase setting is off (AutolaunchWeb.Showcase).
  scope "/", AutolaunchWeb do
    pipe_through [:motion_lab, :browser, :browser_session]

    live_session :motion_lab,
      session: {AutolaunchWeb.Live.Session, :render_context, []},
      on_mount: [
        {AutolaunchWeb.Showcase, :motion_lab},
        {AutolaunchWeb.Live.Session, :load_human},
        {AutolaunchWeb.Live.Credits, :credits}
      ] do
      live "/animations", AnimationsLive, :index
    end
  end

  scope "/admin" do
    pipe_through :errors_admin

    error_tracker_dashboard("/errors",
      on_mount: [AutolaunchWeb.ErrorsAdmin],
      csp_nonce_assign_key: %{script: :csp_nonce, style: :csp_nonce}
    )
  end
end
