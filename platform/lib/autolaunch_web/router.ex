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

  def enforce_session_authority(conn, _opts) do
    if Autolaunch.Prelaunch.read_only?() do
      conn |> assign(:current_lineage, nil) |> assign(:current_human_account, nil)
    else
      AutolaunchWeb.PrivySessionController.enforce_authority(conn)
    end
  end

  scope "/", AutolaunchWeb do
    # The platform health check answers before sessions, flash or CSRF.
    get "/healthz", HealthController, :show
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
      live "/create", CreateLive, :create
      live "/create/stocks", StocksCreateLive, :create
      live "/auctions", AuctionsLive, :index
      live "/auctions/:auction_id", AuctionLive, :show
      live "/tokens", TokensLive, :index
      live "/tokens/:token_id", TokenLive, :show
      live "/launches", LaunchesLive, :index
      live "/launches/:id", LaunchLive, :show
      live "/subjects", SubjectsLive, :index
      live "/subjects/:id", SubjectLive, :show
      live "/portfolio", PortfolioLive, :portfolio
      live "/regent", RegentLive, :regent
    end
  end
end
