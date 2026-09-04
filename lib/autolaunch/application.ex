defmodule Autolaunch.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Autolaunch.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc false
  def children do
    [
      AutolaunchWeb.Telemetry,
      {Autolaunch.Accounts.BootstrapRateLimiter, []},
      Autolaunch.Repo,
      autolaunch_indexer_child(),
      {Phoenix.PubSub, name: Autolaunch.PubSub},
      autolaunch_lab_market_feed_child(),
      # Start a worker by calling: Autolaunch.Worker.start_link(arg)
      # {Autolaunch.Worker, arg},
      # Start to serve requests, typically the last entry
      AutolaunchWeb.Endpoint
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The Base log ledger is optional and starts after the repository it writes
  # to. A dedicated nonempty endpoint is the only thing that turns it on.
  defp autolaunch_indexer_child do
    with true <- Application.get_env(:autolaunch, :database_startup_enabled, false),
         endpoint when is_binary(endpoint) and endpoint != "" <-
           Application.get_env(:autolaunch, :autolaunch_indexer_rpc_url) do
      {Autolaunch.DurableWork.Runner,
       handler: Module.concat(Autolaunch.Indexer, "Handler"),
       poll_interval_ms: 2_000,
       max_in_flight: 1}
    else
      _disabled -> nil
    end
  end

  defp autolaunch_lab_market_feed_child do
    with true <- Application.get_env(:autolaunch, :database_startup_enabled, false),
         true <- Application.get_env(:autolaunch, :autolaunch_lab_enabled, false),
         true <- Application.get_env(:autolaunch, :autolaunch_lab_acceptance_verified, false),
         {:ok, _config} <- Autolaunch.Lab.current() do
      Autolaunch.LabMarketFeed
    else
      _disabled -> nil
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AutolaunchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
