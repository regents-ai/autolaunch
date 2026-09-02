defmodule AutolaunchWeb.Router do
  use AutolaunchWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AutolaunchWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AutolaunchWeb do
    # The platform health check answers before sessions, flash or CSRF.
    get "/healthz", HealthController, :show
  end

  scope "/", AutolaunchWeb do
    pipe_through :browser

    get "/", PageController, :home
  end
end
