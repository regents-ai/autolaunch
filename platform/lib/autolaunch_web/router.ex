defmodule AutolaunchWeb.Router do
  use AutolaunchWeb, :router

  pipeline :browser do
    plug :accepts, ["html", "json"]
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

  def enforce_session_authority(conn, _opts),
    do: AutolaunchWeb.PrivySessionController.enforce_authority(conn)

  scope "/", AutolaunchWeb do
    # The platform health check answers before sessions, flash or CSRF.
    get "/healthz", HealthController, :show

    # The pictures shared auction links show, read by sites without a session.
    get "/auctions/:auction_id/share.png", ShareCardController, :base
    get "/robinhood/auctions/:auction/share.png", ShareCardController, :robinhood
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
    get "/treasury-security/:address", TreasuryController, :show
  end

  scope "/", AutolaunchWeb do
    pipe_through :browser

    get "/profile", SharedProfileController, :show
    get "/settings", SettingsController, :show
    get "/create/stocks", CreateRedirectController, :stocks

    live_session :public_root,
      session: {AutolaunchWeb.Live.Session, :render_context, []},
      on_mount: [{AutolaunchWeb.Live.Session, :public_human}] do
      live "/", HomeLive, :home
    end

    get "/blog", BlogController, :index
    get "/blog/:slug", BlogController, :show

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
      on_mount: [{AutolaunchWeb.Live.Session, :load_human}, AutolaunchWeb.Live.PageTitle] do
      live "/create", CreateLive, :create
      live "/auctions", AuctionsLive, :index
      live "/auctions/:auction_id", AuctionLive, :show
      live "/robinhood/auctions/:auction", RobinhoodAuctionLive, :show
      live "/tokens", TokensLive, :index
      live "/tokens/:token_id", TokenLive, :show
      live "/robinhood/tokens/:token", RobinhoodTokenLive, :show
      live "/how-it-works", HowItWorksLive, :show
      live "/portfolio", PortfolioLive, :portfolio
      live "/regent", RegentLive, :regent
      live "/convert", ConvertLive, :index
    end
  end
end
