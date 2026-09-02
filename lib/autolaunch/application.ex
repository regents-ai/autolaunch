defmodule Autolaunch.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AutolaunchWeb.Telemetry,
      {Autolaunch.Accounts.BootstrapRateLimiter, []},
      Autolaunch.Repo,
      {Phoenix.PubSub, name: Autolaunch.PubSub},
      # Start a worker by calling: Autolaunch.Worker.start_link(arg)
      # {Autolaunch.Worker, arg},
      # Start to serve requests, typically the last entry
      AutolaunchWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Autolaunch.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AutolaunchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
