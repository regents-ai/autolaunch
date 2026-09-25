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
      the last indexed block, for `indexer` (`:ledger`, `:auction_activity`
      or `:token_trades`) on `chain_id`. The ledger compares its cursor with
      the safe head at the start of each pass, the other two their new cursor
      with the latest head after each committed pass.
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

  The metrics port listens on Fly's private network only: the public proxy
  routes nothing but `[http_service]`, so the numbers are never public. It
  starts only where `:metrics_port` is configured (production).
  """

  use Supervisor

  require Logger

  import Ecto.Query
  import Telemetry.Metrics

  @wallet_failures ~w(not_started not_sent submission_unknown wallet_unavailable network_mismatch wallet_declined send_unconfirmed)

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics(), name: reporter(), start_async: false},
      {:telemetry_poller, measurements: [], period: 10_000},
      metrics_listener(Application.get_env(:autolaunch, :metrics_port))
    ]

    children
    |> Enum.reject(&is_nil/1)
    |> Supervisor.init(strategy: :one_for_one)
  end

  @doc "The Prometheus reporter the metrics port scrapes."
  def reporter, do: :autolaunch_prometheus

  @doc "The site health set, as Prometheus series."
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
      )
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

  # The poller drops a measurement that raises for good, so a database that
  # cannot answer this tick skips it; the next tick measures again.
  @doc false
  def oldest_unfinished_jobs do
    measure_oldest_unfinished_jobs()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("background job age not measured: #{Exception.message(error)}")
  end

  # Only running queues are measured: a paused queue (the finishing queue
  # while the finisher is off) holds its jobs on purpose, and its age would
  # only grow.
  defp measure_oldest_unfinished_jobs do
    %{prefix: prefix} = Oban.config()
    running = for %{queue: queue, paused: false} <- Oban.check_all_queues(), do: queue

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
