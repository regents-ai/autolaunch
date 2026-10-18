defmodule Autolaunch.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  import Cachex.Spec, only: [expiration: 1, hook: 1]

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
      Autolaunch.Accounts.RequestRateLimiter,
      AutolaunchWeb.ShareCard.Cache,
      # The share videos made lately (AutolaunchWeb.ShareVideo), the oldest
      # written leaving first past the limit.
      Supervisor.child_spec(
        {Cachex,
         name: AutolaunchWeb.ShareVideo.cache(),
         expiration: expiration(default: :timer.minutes(30), interval: :timer.minutes(1)),
         hooks: [
           hook(module: Cachex.Limit.Scheduled, args: {AutolaunchWeb.ShareVideo.kept(), [], []})
         ]},
        id: AutolaunchWeb.ShareVideo.cache()
      ),
      public_auctions_child(),
      Supervisor.child_spec(
        {Cachex,
         name: Autolaunch.DexScreener.cache(),
         expiration: expiration(default: :timer.minutes(1), interval: :timer.seconds(10)),
         hooks: [hook(module: Cachex.Limit.Scheduled, args: {1_000, [], []})]},
        id: Autolaunch.DexScreener.cache()
      ),
      Autolaunch.Repo,
      {Phoenix.PubSub, name: Autolaunch.PubSub},
      # After the repository and PubSub: a Credits balance changed, or an agent
      # paired or unpaired, on any Regent site reaches the Account page.
      RegentCredits.Listener,
      RegentAgents.Listener,
      # The figures every visitor sees alike, and their measurements. Before the
      # market feeds that keep them and the endpoint whose pages read them.
      Autolaunch.SharedReading,
      AutolaunchWeb.Telemetry.shared_reading_poller(),
      AutolaunchWeb.Telemetry.Announcements,
      # Reads run apart from the request, so one that fails or hangs is answered, not crashed.
      {Task.Supervisor, name: Autolaunch.TaskSupervisor},
      Autolaunch.Stocks.MarketData,
      Autolaunch.RegentFacts,
      Autolaunch.MarketTicker,
      Supervisor.child_spec({Cachex, name: Autolaunch.Stocks.Assets.cache()},
        id: Autolaunch.Stocks.Assets.cache()
      ),
      autolaunch_indexer_children(),
      auction_activity_child(),
      token_trades_child(),
      autolaunch_jobs_child(),
      stock_admissions_child(),
      autolaunch_lab_market_feed_child(),
      autolaunch_stocks_lab_market_feed_child(),
      autolaunch_robinhood_market_feed_child(),
      # Start a worker by calling: Autolaunch.Worker.start_link(arg)
      # {Autolaunch.Worker, arg},
      # Start to serve requests, typically the last entry
      AutolaunchWeb.Endpoint,
      # After the endpoint, whose open connections it counts.
      AutolaunchWeb.Telemetry.site_poller()
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  # The public auction list, each answer kept for five seconds (at most a
  # thousand different lists), so callers asking again and again share one read.
  defp public_auctions_child do
    {Cachex,
     name: AutolaunchWeb.AuctionController.cache(),
     expiration: expiration(default: :timer.seconds(5), interval: :timer.seconds(1)),
     hooks: [hook(module: Cachex.Limit.Scheduled, args: {1_000, [], []})]}
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

  # The stocks each launchpad admits are read from the chain as soon as a
  # server starts, then every five minutes (`Autolaunch.Stocks.Stock`). After
  # the jobs child, which runs the read. Not under ExUnit, where no job runs
  # unless a test asks for it.
  defp stock_admissions_child do
    if !Autolaunch.Prelaunch.read_only?() and
         Application.get_env(:autolaunch, :database_startup_enabled, false) and
         Application.fetch_env!(:autolaunch, Oban)[:testing] != :manual do
      Supervisor.child_spec(
        {Task, fn -> AshOban.schedule(Autolaunch.Stocks.Stock, :sync_admissions) end},
        id: :stock_admissions_at_start
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

  # Background jobs, which finish ended auctions and check Credits purchases, run
  # once launches are open, with the poller that measures how long their oldest
  # job has waited. AshOban adds a sweep for every trigger in the site's domains
  # and in Regent Credits, whose purchase checks run on this site's Oban.
  defp autolaunch_jobs_child do
    with false <- Autolaunch.Prelaunch.read_only?(),
         true <- Application.get_env(:autolaunch, :database_startup_enabled, false) do
      [
        {Oban,
         AshOban.config(
           Application.fetch_env!(:autolaunch, :ash_domains) ++ [RegentCredits],
           Application.fetch_env!(:autolaunch, Oban)
         )},
        AutolaunchWeb.Telemetry.jobs_poller()
      ]
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
