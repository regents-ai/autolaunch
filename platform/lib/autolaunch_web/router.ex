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

  pipeline :browser_session do
    plug :fetch_session
    plug :enforce_session_authority
    plug :fetch_live_flash
    plug :put_root_layout, html: {AutolaunchWeb.Layouts, :root}
    plug AutolaunchWeb.Plugs.Theme
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Every page can start sign-in from its top bar.
    plug :put_content_security_policy, :sign_in
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The public reads carry no cookie and need no sign-in, so any website's
  # page may read them from its own visitors' browsers.
  pipeline :public_read do
    plug :allow_any_origin
  end

  # Their rate-limit headers are readable too, so such a page can pace itself.
  def allow_any_origin(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header(
      "access-control-expose-headers",
      "ratelimit, ratelimit-policy, retry-after"
    )
  end

  # The signed-in person's own session API; never agent authority.
  pipeline :session_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :enforce_session_authority
    plug :protect_from_forgery
  end

  # The signed-in person's own share video: the session names the account.
  pipeline :session_video do
    plug :fetch_session
    plug :enforce_session_authority
    plug :protect_from_forgery
  end

  # The saved errors: Credits admins only. Anyone else gets the not-found page under
  # the reading policy; an admin's page replaces it with one carrying this
  # request's nonce (AutolaunchWeb.ErrorsAdmin).
  pipeline :errors_admin do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :enforce_session_authority
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"referrer-policy" => "no-referrer"}
    plug :put_content_security_policy, :reading
    plug AutolaunchWeb.ErrorsAdmin
  end

  pipeline :motion_lab do
    plug :admit_motion_lab
  end

  def admit_motion_lab(conn, _opts), do: AutolaunchWeb.Showcase.admit(conn, :motion_lab)

  # Covered-call routes exist only while the site offers covered calls; off,
  # each answers as an address with nothing at it.
  pipeline :covered_calls do
    plug :admit_covered_calls
  end

  def admit_covered_calls(conn, _opts) do
    Autolaunch.CoveredCalls.Deployment.enabled?() or
      raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__

    conn
  end

  # Exposure's routes exist only while the site offers Exposure; off, each
  # answers as an address with nothing at it.
  pipeline :exposure do
    plug :admit_exposure
  end

  def admit_exposure(conn, _opts) do
    Autolaunch.Exposure.Deployment.enabled?() or
      raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__

    conn
  end

  # Claude's page exists only while its connector is on (`Autolaunch.OAuth`);
  # off, it answers as an address with nothing at it.
  pipeline :claude_connector do
    plug :admit_claude_connector
  end

  def admit_claude_connector(conn, _opts) do
    Autolaunch.OAuth.enabled?() or
      raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__

    conn
  end

  def enforce_session_authority(conn, _opts),
    do: AutolaunchWeb.PrivySessionController.enforce_authority(conn)

  # Replaces the default policy put_secure_browser_headers sets with the page's
  # profile, read per request so the router does not compile against it.
  def put_content_security_policy(conn, :sign_in),
    do: put_resp_header(conn, "content-security-policy", ContentSecurityPolicy.sign_in())

  def put_content_security_policy(conn, :reading),
    do: put_resp_header(conn, "content-security-policy", ContentSecurityPolicy.reading())

  scope "/", AutolaunchWeb do
    # The platform health check answers before sessions, flash or CSRF.
    get "/healthz", HealthController, :show

    # The pictures shared auction and token links show, read by sites without
    # a session.
    get "/auctions/:symbol/:tail/share.png", ShareCardController, :auction
    get "/auctions/:symbol/:tail/share.mp4", ShareCardController, :auction_video
    get "/tokens/:symbol/:tail/share.png", ShareCardController, :token
    get "/tokens/:symbol/:tail/share.mp4", ShareCardController, :token_video

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
    get "/llms-full.txt", PublicPagesController, :full_agent_guide
    get "/agents.md", PublicPagesController, :signed_agent_guide
    get "/skill.md", PublicPagesController, :skill_guide
    get "/sitemap.xml", PublicPagesController, :sitemap
    get "/sitemap.md", PublicPagesController, :markdown_sitemap
    get "/openapi.json", PublicPagesController, :openapi
    get "/robots.txt", PublicPagesController, :robots
    get "/capabilities", PublicPagesController, :capabilities
    get "/.well-known/security.txt", PublicPagesController, :security
    get "/.well-known/api-catalog", PublicPagesController, :api_catalog

    # The developer guide's earlier address; links to it were shared.
    get "/developers", PublicPagesController, :developers
  end

  # The Claude connector's sign-in (Autolaunch.OAuth). API credentials never use
  # cookies; consent uses the verified browser session and CSRF. The resource's
  # metadata also answers under its /mcp path, where RFC 9728 places it. While
  # the connector is off, every one of these answers not found.
  scope "/", AutolaunchWeb do
    pipe_through :api
    get "/.well-known/oauth-protected-resource", OAuthController, :resource_metadata
    get "/.well-known/oauth-protected-resource/mcp", OAuthController, :resource_metadata
    get "/.well-known/oauth-authorization-server", OAuthController, :server_metadata
    post "/oauth/register", OAuthController, :register, log: false
    post "/oauth/token", OAuthController, :token, log: false
    post "/oauth/revoke", OAuthController, :revoke, log: false
  end

  scope "/oauth", AutolaunchWeb do
    pipe_through [:browser, :browser_session]
    get "/authorize", OAuthController, :authorize, log: false
    post "/authorize", OAuthController, :approve, log: false
    get "/connections", OAuthController, :connections, log: false
    post "/connections/revoke", OAuthController, :revoke_connection, log: false
  end

  # The hosted MCP server: AshAi runs the tools the capabilities list as hosted
  # (`AutolaunchWeb.Capabilities.hosted_tools/0`), each as its Ash action with its
  # policies. McpAgent admits the request first: POST /mcp alone, JSON, one call,
  # no query string and no page from another site; then a paired agent signing
  # with its wallet or an app connected with a Bearer token from the sign-in
  # above, never neither. A connected app whose identity is paired calls as that
  # agent. So AshAi's own origin check takes whatever McpAgent let through. A
  # tool's input is checked as its action takes it, and refused with the code
  # HTTP gives (`AutolaunchWeb.ToolErrors.check_input/3`). No session, cookie or
  # CSRF token is read. Each account has its own budget here; the endpoint counts
  # each address first. Nothing is kept between requests. Tool calls carry pairing
  # codes, so nothing is logged. There is no `:accepts`: the endpoint already
  # answers /mcp in JSON, so a GET for an event stream hears McpAgent's 405, not a
  # 406.
  pipeline :mcp do
    plug AutolaunchWeb.Plugs.McpAgent
  end

  scope "/" do
    pipe_through :mcp

    forward "/mcp",
            AshAi.Mcp.Router,
            [
              otp_app: :autolaunch,
              tools: AutolaunchWeb.Capabilities.hosted_tools(),
              mcp_name: "autolaunch",
              instructions:
                "Autolaunch, where agents and their people back long-term agents through fair token auctions. " <>
                  "Every call is signed by a paired agent's own wallet, or carries the token of an app a person " <>
                  "connected to their account here. autolaunch_auction_counts reads how many auctions are live " <>
                  "and graduated; regents mcp signs each call for an agent. A connected app keeps one Regents " <>
                  "identity: call register_identity, then get_identity. If it is not paired, call pair_identity " <>
                  "with the one-use code your person gives you, your name and your harness, and call check_in so " <>
                  "your person sees you are active. Once paired, you work here as that agent: its tools are yours " <>
                  "as they are any paired agent's. Never ask for a password, a private key or a wallet signature.",
              list_ttl_ms: 0,
              read_ttl_ms: 0,
              cache_scope: "private",
              allowed_origins: &is_binary/1,
              tool_argument_transformer: &AutolaunchWeb.ToolErrors.check_input/3
            ],
            log: false
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

  scope "/api/agent/v1", AutolaunchWeb do
    pipe_through [:api, :covered_calls]
    get "/covered-calls/:symbol/positions", CoveredCallsAgentController, :positions
    post "/covered-calls/:symbol/steps", CoveredCallsAgentController, :prepare
  end

  scope "/api/agent/v1", AutolaunchWeb do
    pipe_through [:api, :exposure]
    get "/after-hour-stocks/:series/holdings", ExposureAgentController, :holdings
    post "/after-hour-stocks/:series/steps", ExposureAgentController, :prepare
  end

  scope "/api/v1" do
    pipe_through :api
    forward "/profile", RegentIdentity.HTTP, otp_app: :autolaunch
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through [:api, :public_read]

    get "/auctions", AuctionController, :index
    get "/auction-counts", AuctionController, :counts
    get "/auctions/:id", AuctionController, :show
    get "/tokens", TokenController, :index
    get "/tokens/:id", TokenController, :show
    get "/treasury-security/:address", TreasuryController, :show
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through :api

    post "/auctions/:id/bid-quote", AuctionController, :bid_quote
  end

  # Covered calls' styles, at the address the other styles share; off, nothing is there.
  scope "/assets/js", AutolaunchWeb do
    pipe_through :covered_calls

    get "/covered_calls.css", CoveredCallsController, :stylesheet
  end

  # Exposure's styles, at the address the other styles share; off, nothing is there.
  scope "/assets/js", AutolaunchWeb do
    pipe_through :exposure

    get "/exposure.css", ExposureController, :stylesheet
  end

  # A series' terms, the exact bytes its `termsHash` fingerprints, and the
  # picture and video a shared series link shows.
  scope "/after-hour-stocks", AutolaunchWeb do
    pipe_through :exposure

    get "/terms/:hash", ExposureController, :terms
    get "/:series/share.png", ShareCardController, :exposure
    get "/:series/share.mp4", ShareCardController, :exposure_video
  end

  # The picture and video a shared covered-calls link shows.
  scope "/covered-calls", AutolaunchWeb do
    pipe_through :covered_calls

    get "/:symbol/share.png", ShareCardController, :covered_calls
    get "/:symbol/share.mp4", ShareCardController, :covered_calls_video
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through [:api, :public_read, :exposure]

    get "/after-hour-stocks", ExposureController, :index
    get "/after-hour-stocks/:series", ExposureController, :show
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through [:api, :public_read, :covered_calls]

    get "/covered-calls/:symbol", CoveredCallsController, :book
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through [:api, :covered_calls]

    post "/covered-calls/:symbol/quote", CoveredCallsController, :quote
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through :session_api

    get "/me/positions", MyPositionsController, :show
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through [:session_api, :covered_calls]

    get "/me/covered-calls/:symbol", CoveredCallsController, :mine
  end

  scope "/api/v1", AutolaunchWeb do
    pipe_through [:session_api, :exposure]

    get "/me/after-hour-stocks/:series", ExposureController, :mine
  end

  # A wallet's own share video, for the signed-in account that links it.
  scope "/", AutolaunchWeb do
    pipe_through :session_video

    get "/tokens/:symbol/:tail/wallets/:wallet/share.mp4", ShareCardController, :wallet_video

    get "/auctions/:symbol/:tail/wallets/:wallet/share.mp4",
        ShareCardController,
        :auction_wallet_video
  end

  scope "/covered-calls", AutolaunchWeb do
    pipe_through [:session_video, :covered_calls]

    get "/:symbol/wallets/:wallet/share.mp4", ShareCardController, :covered_calls_wallet_video
  end

  scope "/after-hour-stocks", AutolaunchWeb do
    pipe_through [:session_video, :exposure]

    get "/:series/wallets/:wallet/share.mp4", ShareCardController, :exposure_wallet_video
  end

  scope "/", AutolaunchWeb do
    pipe_through [:browser_auth, :browser_session]

    get "/auth/csrf", PrivySessionController, :csrf
    post "/visit-log", VisitLogController, :create, log: false
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
        {AutolaunchWeb.Live.Credits, :credits},
        {AutolaunchWeb.Live.Agents, :agents}
      ] do
      live "/", HomeLive, :home
    end

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
        {AutolaunchWeb.Live.Credits, :credits},
        {AutolaunchWeb.Live.Agents, :agents}
      ] do
      live "/create", StocksCreateLive, :create
      live "/create/revstake", CreateLive, :create
      live "/auctions", AuctionsLive, :index
      live "/auctions/:symbol/:tail", MarketPageLive, :auction
      live "/tokens", TokensLive, :index
      live "/tokens/:symbol/:tail", MarketPageLive, :token
      live "/stock-listing", UpcomingLive, :show
      live "/stock-listing/:symbol", StockLive, :show
      live "/covered-calls", CoveredCallsLive, :index
      live "/after-hour-stocks", ExposureLive, :show
      live "/how-it-works", HowItWorksLive, :show
      live "/portfolio", PortfolioLive, :portfolio
      live "/portfolio/bids/:id", BidLive, :bid
      live "/account", AccountLive, :account
      live "/account/points", PointsLive, :points
      live "/regent", RegentLive, :regent
      live "/convert", ConvertLive, :index
    end
  end

  scope "/", AutolaunchWeb do
    pipe_through [:claude_connector, :browser, :browser_session]

    get "/agents/claude", PublicPagesController, :show
  end

  # The motion lab, unless the showcase setting is off (AutolaunchWeb.Showcase).
  scope "/", AutolaunchWeb do
    pipe_through [:motion_lab, :browser, :browser_session]

    live_session :motion_lab,
      session: {AutolaunchWeb.Live.Session, :render_context, []},
      on_mount: [
        {AutolaunchWeb.Showcase, :motion_lab},
        {AutolaunchWeb.Live.Session, :load_human},
        {AutolaunchWeb.Live.Credits, :credits},
        {AutolaunchWeb.Live.Agents, :agents}
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
