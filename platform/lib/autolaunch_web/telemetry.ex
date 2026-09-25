defmodule AutolaunchWeb.Telemetry do
  @moduledoc """
  The site's health measurements, as `:telemetry` events. Nothing in the app
  collects or shows them yet: a handler or metrics reporter attaches to these
  names.

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
      available, running or retrying background job in `queue`, 0 when there
      is none, every ten seconds while background jobs run. A paused queue
      keeps its jobs waiting on purpose.
    * `[:autolaunch, :rpc, :failure]` — `count` 1 for each chain request that
      got no answer, by `method`, `class`, `chain_id` and `scope`.
    * `[:autolaunch, :repo, :query]` — Ecto's own event per query, whose
      `queue_time` is the wait for a database connection.
    * `[:autolaunch, :wallet, :failure]` — `count` 1 for each wallet send the
      browser reported as not made or not confirmed, by `flow` and `reason`.
  """

  use Supervisor

  import Ecto.Query

  @wallet_failures ~w(not_started not_sent submission_unknown wallet_unavailable network_mismatch wallet_declined send_unconfirmed)

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: [], period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The poller that measures the background job queues, started beside Oban."
  def jobs_poller,
    do:
      {:telemetry_poller,
       measurements: [{__MODULE__, :oldest_unfinished_jobs, []}],
       period: 10_000,
       name: :autolaunch_jobs_poller}

  @doc false
  def oldest_unfinished_jobs do
    %{prefix: prefix, queues: queues} = Oban.config()

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

    for {queue, _limit} <- queues do
      age_ms =
        case oldest[to_string(queue)] do
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
