defmodule AutolaunchWeb.TelemetryTest do
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 2]

  alias Autolaunch.Repo
  alias Ecto.Adapters.SQL.Sandbox

  # Every site's dashboard reads request and query time by these names, so a
  # request and a query must each land in the scrape.
  test "a request is timed by its route pattern and a query by its whole time" do
    :ok = Sandbox.checkout(Repo)

    :get |> conn("/sitemap.xml") |> AutolaunchWeb.Endpoint.call(AutolaunchWeb.Endpoint.init([]))
    Repo.query!("SELECT 1")

    scrape = AutolaunchWeb.Telemetry.scrape()

    assert scrape =~
             ~r/^autolaunch_request_duration_microseconds_count\{route="\/sitemap.xml"\} [1-9]/m

    assert scrape =~ ~r/^autolaunch_repo_query_microseconds_count [1-9]/m
  end

  # A job made an hour ago to run a minute ago has waited a minute, and one
  # between attempts has not waited at all.
  test "a queue's oldest job is aged from when it was due, not from when it was made" do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    # Two running queues and nothing else: no schedule, pruning or rescue.
    start_supervised!(
      {Oban,
       :autolaunch
       |> Application.fetch_env!(Oban)
       |> Keyword.merge(
         testing: :disabled,
         queues: [gauge_due: 1, gauge_retrying: 1],
         peer: false,
         cron: false,
         pruner: false,
         lifeline: false
       )}
    )

    now = DateTime.utc_now()

    for {queue, state, due_at} <- [
          {:gauge_due, "executing", DateTime.add(now, -60)},
          {:gauge_retrying, "retryable", DateTime.add(now, 600)}
        ] do
      %{}
      |> Oban.Job.new(worker: "Gauge", queue: queue, scheduled_at: due_at)
      |> Ecto.Changeset.change(state: state, inserted_at: DateTime.add(now, -3_600))
      |> Oban.insert!()
    end

    wait_for_queues([:gauge_due, :gauge_retrying])

    test = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:autolaunch, :jobs, :oldest_unfinished],
      fn _event, %{age_ms: age_ms}, %{queue: queue}, _config ->
        send(test, {:age, queue, age_ms})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    AutolaunchWeb.Telemetry.oldest_unfinished_jobs()

    assert_received {:age, "gauge_due", age_ms}
    assert age_ms in 60_000..120_000
    assert_received {:age, "gauge_retrying", 0}
  end

  defp wait_for_queues(queues, tries \\ 50) do
    running = for %{queue: queue, paused: false} <- Oban.check_all_queues(), do: queue

    cond do
      Enum.all?(queues, &(Atom.to_string(&1) in running)) -> :ok
      tries == 0 -> flunk("queues did not start: #{inspect(running)}")
      true -> Process.sleep(20) && wait_for_queues(queues, tries - 1)
    end
  end
end
