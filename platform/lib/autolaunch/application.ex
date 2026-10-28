defmodule Autolaunch.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  import Cachex.Spec, only: [expiration: 1, hook: 1]

  @impl true
  def start(_type, _args) do
    # Every outbound TLS connection trusts castore's list, not the operating
    # system's: castore drops a compromised root as soon as Mozilla does, which a
    # Debian image can lag by weeks. Req, Finch and Mint read this list through
    # `:public_key.cacerts_get/0`, so it is loaded before anything connects.
    :ok = :public_key.cacerts_load(CAStore.file_path())
    :ok = AutolaunchWeb.VisitLog.Events.attach()

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
      # The launch images made at the sizes pages show them
      # (Autolaunch.StoredImage), the oldest written leaving first past the limit.
      Supervisor.child_spec(
        {Cachex,
         name: Autolaunch.StoredImage.cache(),
         hooks: [
           hook(module: Cachex.Limit.Scheduled, args: {Autolaunch.StoredImage.kept(), [], []})
         ]},
        id: Autolaunch.StoredImage.cache()
      ),
      Autolaunch.StoredImage.Resizer,
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
      # chain heads that keep them and the endpoint whose pages read them.
      Autolaunch.SharedReading,
      AutolaunchWeb.Telemetry.shared_reading_poller(),
      AutolaunchWeb.Telemetry.Announcements,
      # Reads run apart from the request, so one that fails or hangs is answered, not crashed.
      {Task.Supervisor, name: Autolaunch.TaskSupervisor},
      Autolaunch.Stocks.MarketData,
      Autolaunch.RegentFacts,
      Autolaunch.CoveredCalls.Book,
      Autolaunch.MarketTicker,
      Supervisor.child_spec({Cachex, name: Autolaunch.Stocks.Assets.cache()},
        id: Autolaunch.Stocks.Assets.cache()
      ),
      autolaunch_jobs_child(),
      stock_admissions_child(),
      chain_head_children(),
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

  # Background jobs, which read the chain (`Autolaunch.ChainWatch`), finish ended
  # auctions and check Credits purchases, run once launches are open, with the
  # poller that measures how long their oldest job has waited. AshOban adds a
  # sweep for every trigger in the site's domains and in Regent Credits, whose
  # purchase checks run on this site's Oban.
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

  # Each deployment's newest block, read on every machine that serves pages
  # (`Autolaunch.ChainHead`).
  defp chain_head_children do
    if !Autolaunch.Prelaunch.read_only?() and
         Phoenix.Endpoint.server?(:autolaunch, AutolaunchWeb.Endpoint),
       do: Autolaunch.ChainHead.children()
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AutolaunchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
