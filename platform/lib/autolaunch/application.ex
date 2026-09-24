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
      {Phoenix.PubSub, name: Autolaunch.PubSub},
      Autolaunch.Stocks.MarketData,
      Autolaunch.RegentFacts,
      autolaunch_indexer_children(),
      autolaunch_lab_market_feed_child(),
      autolaunch_stocks_lab_market_feed_child(),
      # Start a worker by calling: Autolaunch.Worker.start_link(arg)
      # {Autolaunch.Worker, arg},
      # Start to serve requests, typically the last entry
      AutolaunchWeb.Endpoint
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  # The log ledger is optional and starts after the repository it writes to and
  # the notifier it will publish through. Each configured chain gets its own
  # runner, so one chain's endpoint failing leaves the others and the site
  # running; a malformed chain list refuses to boot.
  defp autolaunch_indexer_children do
    with false <- Autolaunch.Prelaunch.read_only?(),
         true <- Application.get_env(:autolaunch, :database_startup_enabled, false) do
      Enum.map(Autolaunch.Indexer.Chains.configured(), &autolaunch_indexer_child/1)
    else
      _disabled -> []
    end
  end

  defp autolaunch_indexer_child(%{chain_id: chain_id}) do
    Supervisor.child_spec(
      {Autolaunch.DurableWork.Runner,
       handler: Autolaunch.Indexer.Handler,
       context: chain_id,
       poll_interval_ms: 2_000,
       max_in_flight: 1},
      id: {Autolaunch.Indexer, chain_id}
    )
  end

  defp autolaunch_lab_market_feed_child do
    with false <- Autolaunch.Prelaunch.read_only?(),
         true <- Application.get_env(:autolaunch, :database_startup_enabled, false),
         {:ok, _config} <- Autolaunch.Lab.current() do
      Autolaunch.LabMarketFeed
    else
      _disabled -> nil
    end
  end

  # The Stocks feed runs only when the Stocks description extends the Base one.
  defp autolaunch_stocks_lab_market_feed_child do
    with false <- Autolaunch.Prelaunch.read_only?(),
         true <- Application.get_env(:autolaunch, :database_startup_enabled, false),
         {:ok, _config} <- Autolaunch.Stocks.Lab.current() do
      Autolaunch.Stocks.LabMarketFeed
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
