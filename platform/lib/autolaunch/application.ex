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
      auction_activity_child(),
      revenue_payments_child(),
      token_trades_child(),
      autolaunch_jobs_child(),
      autolaunch_lab_market_feed_child(),
      autolaunch_stocks_lab_market_feed_child(),
      autolaunch_robinhood_market_feed_child(),
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
  defp auction_activity_child do
    if !Autolaunch.Prelaunch.read_only?() and
         Application.get_env(:autolaunch, :database_startup_enabled, false) do
      # A separate historical slot keeps archive backfill from delaying live bids.
      for historical <- [false, true] do
        Supervisor.child_spec(
          {Autolaunch.DurableWork.Runner,
           handler: Autolaunch.AuctionActivity,
           context: historical,
           poll_interval_ms: 1_000,
           max_in_flight: 1},
          id: {Autolaunch.AuctionActivity, historical}
        )
      end
    end
  end

  # The payment history of graduated Base Revstake launches, read from their
  # payment receivers one launch at a time.
  defp revenue_payments_child do
    if !Autolaunch.Prelaunch.read_only?() and
         Application.get_env(:autolaunch, :database_startup_enabled, false) do
      Supervisor.child_spec(
        {Autolaunch.DurableWork.Runner,
         handler: Autolaunch.RevenuePayments, poll_interval_ms: 1_000, max_in_flight: 1},
        id: Autolaunch.RevenuePayments
      )
    end
  end

  # Trades in each launched token's pool, for the ticker at the foot of every page.
  defp token_trades_child do
    if !Autolaunch.Prelaunch.read_only?() and
         Application.get_env(:autolaunch, :database_startup_enabled, false) do
      Supervisor.child_spec(
        {Autolaunch.DurableWork.Runner,
         handler: Autolaunch.TokenTrades, context: nil, poll_interval_ms: 1_000, max_in_flight: 1},
        id: Autolaunch.TokenTrades
      )
    end
  end

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

  # Background jobs, which finish ended auctions, run once launches are open.
  defp autolaunch_jobs_child do
    with false <- Autolaunch.Prelaunch.read_only?(),
         true <- Application.get_env(:autolaunch, :database_startup_enabled, false) do
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    else
      _disabled -> nil
    end
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

  # The Robinhood feed runs whenever a Robinhood deployment is described. It is
  # its own child, so a Robinhood outage never reaches the Base feeds.
  defp autolaunch_robinhood_market_feed_child do
    with false <- Autolaunch.Prelaunch.read_only?(),
         true <- Application.get_env(:autolaunch, :database_startup_enabled, false),
         true <- Autolaunch.Robinhood.Lab.configured?() do
      Autolaunch.Robinhood.MarketFeed
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
