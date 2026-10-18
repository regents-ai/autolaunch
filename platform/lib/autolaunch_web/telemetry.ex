defmodule AutolaunchWeb.Telemetry do
  @moduledoc """
  The site's health measurements, as `:telemetry` events, and their Prometheus
  export. Fly's managed Prometheus scrapes `/metrics` on the private metrics
  port (`fly.toml` `[metrics]`); Fly Sentinel reads the series from there.
  The names and labels follow Fly Sentinel's site health set
  (`docs/business-metrics-contract.md` in fly-sentinel).

    * `[:autolaunch, :chain_event, :recorded]` — `delay_ms` from a bid's or
      trade's block time to when the site recorded it, for `kind` (`:bid` or
      `:trade`) on `chain_id`. Emitted by `Autolaunch.AuctionActivity` and
      `Autolaunch.TokenTrades` on passes that follow the head.
    * `[:autolaunch, :indexer, :lag]` — `blocks` between the chain head and
      the last indexed block, for `indexer` (`:ledger`, `:auction_activity`,
      `:token_trades` or `:stock_admissions`) on `chain_id`. The ledger
      compares its cursor with the safe head at the start of each pass, the
      others their new cursor with the latest head after each committed pass;
      the token trades reader sends the furthest-behind cursor among the
      chain's listed tokens that have one, not only the token it just read;
      the stock list sends it only for a pass that left no stock unread. Each
      event also counts one pass, so a reader that stops shows as passes that
      stop rising while its lag keeps its last value.
    * `[:autolaunch, :jobs, :oldest_unfinished]` — `age_ms` of the oldest
      available, running or retrying background job in each running `queue`,
      0 when there is none, every ten seconds while background jobs run. A
      paused queue keeps its jobs waiting on purpose, so it is not measured.
    * `[:autolaunch, :rpc, :failure]` — `count` 1 for each chain request that
      got no answer, by `method`, `class`, `chain_id` and `scope`.
    * `[:autolaunch, :repo, :query]` — Ecto's own event per query, whose
      `queue_time` is the wait for a database connection.
    * `[:autolaunch, :wallet, :failure]` — `count` 1 for each wallet send the
      browser reported as not made or not confirmed, by `flow` and `reason`.
    * `[:autolaunch, :shared_reading, ...]` — the figures every visitor sees
      alike (`Autolaunch.SharedReading`): for each `kind`, how many keys are
      held, how many have never been read and how long ago the oldest was
      read, every ten seconds; each reading that could not be taken; each one
      refused; each wake-up sent to open pages; the table's size.
    * `[:autolaunch, :auction_page, :ladder_stopped]` — `count` 1 each time a
      market feed's pass leaves an auction's price ladder unfinished: the
      auction has more prices than a ladder lists, or the chain answered too
      slowly to read them in one pass (`Autolaunch.AuctionSnapshot`).
    * `[:autolaunch, :pages, :announced]` — `count` 1 for each announcement
      the site makes to its open pages, by `kind` (`:listings` or `:ticker`).
      Every open page acts on each one, so a high rate with nobody bidding
      means pages are refreshing for nothing.
    * `[:autolaunch, :pages, :reread]` — `count` 1 each time an open page
      reads its lists again after an announcement, by `view`.
    * `[:autolaunch, :site, :connections]` — `open`, the connections the web
      server holds, every ten seconds. An open page holds one for as long as
      it is open, and Fly's connection ceiling (`fly.toml`) counts the same.

  The metrics port listens on Fly's private network only: the public proxy
  routes nothing but `[http_service]`, so the numbers are never public. It
  starts only where `:metrics_port` is configured (production).
  """

  use Supervisor

  require Logger

  import Ecto.Query
  import Telemetry.Metrics

  @wallet_failures ~w(step_unknown wallet_unavailable network_mismatch wallet_declined insufficient_funds send_unconfirmed)

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics(), name: reporter(), start_async: false},
      metrics_listener(Application.get_env(:autolaunch, :metrics_port))
    ]

    children
    |> Enum.reject(&is_nil/1)
    |> Supervisor.init(strategy: :one_for_one)
  end

  @doc "The Prometheus reporter the metrics port scrapes."
  def reporter, do: :autolaunch_prometheus

  @doc "The site health set and the engine's own measurements, as Prometheus series."
  def metrics do
    [
      distribution("health.chain_event.delay.seconds",
        event_name: [:autolaunch, :chain_event, :recorded],
        measurement: :delay_ms,
        unit: {:millisecond, :second},
        tags: [:kind, :chain_id],
        description: "Seconds from a bid's or trade's block to when the site recorded it",
        reporter_options: [buckets: [1, 2, 5, 10, 20, 30, 60, 120, 300, 600]]
      ),
      last_value("health.indexer.lag.blocks",
        event_name: [:autolaunch, :indexer, :lag],
        measurement: :blocks,
        tags: [:indexer, :chain_id],
        description: "Blocks between the chain head and the indexer's last indexed block"
      ),
      counter("health.indexer.passes.total",
        event_name: [:autolaunch, :indexer, :lag],
        tags: [:indexer, :chain_id],
        description: "Chain reader passes"
      ),
      last_value("health.job.oldest_age.seconds",
        event_name: [:autolaunch, :jobs, :oldest_unfinished],
        measurement: :age_ms,
        unit: {:millisecond, :second},
        tags: [:queue],
        description: "Age of the oldest unfinished background job in the queue"
      ),
      counter("health.chain_request_failures.total",
        event_name: [:autolaunch, :rpc, :failure],
        tags: [:method, :class, :chain_id, :scope],
        tag_values: &chain_failure_labels/1,
        description: "Chain requests that got no answer"
      ),
      distribution("health.db_queue.seconds",
        event_name: [:autolaunch, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :second},
        description: "Seconds a query waited for a database connection",
        reporter_options: [buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]]
      ),
      counter("health.wallet_send_failures.total",
        event_name: [:autolaunch, :wallet, :failure],
        tags: [:flow, :reason],
        description: "Wallet sends the browser reported as not made or not confirmed"
      ),
      counter("health.page_announcements.total",
        event_name: [:autolaunch, :pages, :announced],
        tags: [:kind],
        description: "Announcements the site made to its open pages"
      ),
      counter("health.page_list_reads.total",
        event_name: [:autolaunch, :pages, :reread],
        tags: [:view],
        tag_values: &%{&1 | view: inspect(&1.view)},
        description: "Times an open page read its lists again after an announcement"
      ),
      last_value("health.open_connections",
        event_name: [:autolaunch, :site, :connections],
        measurement: :open,
        description: "Connections the web server holds"
      ),
      last_value("health.shared_reading.oldest.seconds",
        event_name: [:autolaunch, :shared_reading, :kind],
        measurement: :oldest_seconds,
        tags: [:kind],
        description: "Seconds since the oldest shared reading of each kind was read"
      ),
      last_value("health.shared_reading.never_read.keys",
        event_name: [:autolaunch, :shared_reading, :kind],
        measurement: :never_read,
        tags: [:kind],
        description: "Keys of the kind that have had no reading since the site started"
      ),
      counter("health.shared_reading.degraded.total",
        event_name: [:autolaunch, :shared_reading, :degraded],
        tags: [:kind],
        description: "Shared readings that could not be taken"
      ),
      last_value("autolaunch.shared_reading.keys",
        event_name: [:autolaunch, :shared_reading, :kind],
        measurement: :keys,
        tags: [:kind]
      ),
      last_value("autolaunch.shared_reading.table.bytes",
        event_name: [:autolaunch, :shared_reading, :table],
        measurement: :bytes
      ),
      counter("autolaunch.shared_reading.refused.total",
        event_name: [:autolaunch, :shared_reading, :refused],
        tags: [:kind, :reason]
      ),
      counter("autolaunch.shared_reading.woken.total",
        event_name: [:autolaunch, :shared_reading, :woken],
        tags: [:kind]
      ),
      counter("autolaunch.auction_page.ladder_stopped.total",
        event_name: [:autolaunch, :auction_page, :ladder_stopped]
      ),
      distribution("autolaunch.share_video.render.seconds",
        event_name: [:autolaunch, :share_video, :rendered],
        measurement: :ms,
        unit: {:millisecond, :second},
        tags: [:kind],
        description: "Seconds to draw and encode one share video",
        reporter_options: [buckets: [1, 2, 5, 10, 20, 30, 60]]
      ),
      last_value("autolaunch.share_video.peak_memory.bytes",
        event_name: [:autolaunch, :share_video, :rendered],
        measurement: :peak_bytes,
        tags: [:kind],
        description: "The most memory the BEAM held while the last share video was made"
      ),
      last_value("vm.memory.total.bytes", event_name: [:vm, :memory], measurement: :total),
      last_value("vm.memory.processes.bytes",
        event_name: [:vm, :memory],
        measurement: :processes
      ),
      last_value("vm.memory.binary.bytes", event_name: [:vm, :memory], measurement: :binary),
      last_value("vm.memory.ets.bytes", event_name: [:vm, :memory], measurement: :ets),
      last_value("vm.memory.code.bytes", event_name: [:vm, :memory], measurement: :code),
      last_value("vm.memory.atom.bytes", event_name: [:vm, :memory], measurement: :atom),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.atom_count"),
      last_value("vm.system_counts.port_count")
    ]
  end

  # An HTTP refusal arrives as `{:http_status, status}`; a label is text.
  defp chain_failure_labels(%{class: {:http_status, status}} = metadata),
    do: %{metadata | class: "http_#{status}"}

  defp chain_failure_labels(metadata), do: metadata

  defp metrics_listener(nil), do: nil

  defp metrics_listener(port),
    do: {Bandit, plug: AutolaunchWeb.Metrics, port: port, ip: {0, 0, 0, 0, 0, 0, 0, 0}}

  @doc "The poller that measures the background job queues, started beside Oban."
  def jobs_poller,
    do:
      {:telemetry_poller,
       measurements: [{__MODULE__, :oldest_unfinished_jobs, []}],
       period: 10_000,
       name: :autolaunch_jobs_poller}

  @doc "The poller that measures the shared readings, started after their table."
  def shared_reading_poller,
    do:
      {:telemetry_poller,
       measurements: [{Autolaunch.SharedReading, :measure, []}],
       period: 10_000,
       name: :autolaunch_shared_reading_poller}

  @doc "The poller that counts the web server's open connections, started after the endpoint."
  def site_poller,
    do:
      {:telemetry_poller,
       measurements: [{__MODULE__, :open_connections, []}],
       period: 10_000,
       name: :autolaunch_site_poller}

  # Where the endpoint runs no server (tests), there is nothing to count. The
  # poller drops a measurement that exits for good, so a web server supervisor
  # that is restarting or slow to answer this tick skips it; the next tick
  # counts again.
  @doc false
  def open_connections do
    with {:ok, server} when is_pid(server) <-
           Bandit.PhoenixAdapter.bandit_pid(AutolaunchWeb.Endpoint),
         {:ok, connections} <- ThousandIsland.connection_pids(server) do
      :telemetry.execute([:autolaunch, :site, :connections], %{open: length(connections)}, %{})
    end
  catch
    :exit, reason -> Logger.warning("open connections not counted: #{inspect(reason)}")
  end

  # The poller drops for good a measurement that raises or exits, and the row
  # would then keep its last number. So whatever stops this tick (a database
  # that cannot answer, a queue too busy to say whether it runs, Oban or the
  # repo restarting) is logged and skipped; the next tick measures again.
  @doc false
  def oldest_unfinished_jobs do
    measure_oldest_unfinished_jobs()
  rescue
    error -> not_measured(Exception.message(error))
  catch
    :exit, reason -> not_measured(Exception.format_exit(reason))
  end

  defp not_measured(why), do: Logger.warning("background job age not measured: #{why}")

  # Only running queues are measured: a paused queue (the finishing queue
  # while the finisher is off) holds its jobs on purpose, and its age would
  # only grow. Where no queue runs (tests), nothing is read.
  defp measure_oldest_unfinished_jobs do
    case for %{queue: queue, paused: false} <- Oban.check_all_queues(), do: queue do
      [] -> :ok
      running -> report_oldest(running)
    end
  end

  defp report_oldest(running) do
    %{prefix: prefix} = Oban.config()

    oldest =
      from(j in Oban.Job,
        where: j.state in ["available", "executing", "retryable"],
        group_by: j.queue,
        select: {j.queue, min(j.inserted_at)}
      )
      # Oban's job table has no Ash resource; this only reads it.
      |> Autolaunch.Repo.all(prefix: prefix)
      |> Map.new()

    now = DateTime.utc_now()

    for queue <- running do
      age_ms =
        case oldest[queue] do
          nil -> 0
          inserted_at -> DateTime.diff(now, inserted_at, :millisecond)
        end

      :telemetry.execute([:autolaunch, :jobs, :oldest_unfinished], %{age_ms: age_ms}, %{
        queue: queue
      })
    end
  end

  @doc """
  Counts one wallet send the browser reported as not made or not confirmed.
  Only the reasons the browser sends are counted; a report of a sent
  transaction has none.
  """
  def wallet_failed(flow, reason) when reason in @wallet_failures,
    do:
      :telemetry.execute([:autolaunch, :wallet, :failure], %{count: 1}, %{
        flow: flow,
        reason: reason
      })

  def wallet_failed(_flow, _reason), do: :ok
end
