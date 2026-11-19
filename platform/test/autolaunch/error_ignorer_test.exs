defmodule Autolaunch.ErrorIgnorerTest do
  # One Oban instance under its global name, so not async.
  use Autolaunch.DataCase, async: false

  alias ErrorTracker.{Error, Occurrence}

  defmodule FailingJob do
    @moduledoc false
    use Oban.Worker, queue: :error_ignorer_test

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: raise("chain read failed")
  end

  setup do
    start_supervised!({Oban, Application.fetch_env!(:autolaunch, Oban)})
    :ok
  end

  # Oban's own executor runs each attempt in this process, so ErrorTracker's
  # handlers (wrapped by RegentHttp.ErrorSaving at start) see the real start and
  # exception events and save through the configured ignorer.
  describe "a failed job attempt" do
    test "a job with tries left is saved from its second failed attempt, not its first" do
      {:ok, _job} = %{} |> FailingJob.new(max_attempts: 3) |> Oban.insert()

      assert %{failure: 1} = Oban.drain_queue(queue: :error_ignorer_test)
      assert Repo.all(Error) == []

      assert %{failure: 1} =
               Oban.drain_queue(queue: :error_ignorer_test, with_scheduled: true)

      assert [%Error{kind: "Elixir.RuntimeError"}] = Repo.all(Error)
      assert [%Occurrence{context: %{"job.attempt" => 2}}] = Repo.all(Occurrence)
    end

    test "a job whose only attempt failed is saved" do
      {:ok, _job} = %{} |> FailingJob.new(max_attempts: 1) |> Oban.insert()

      assert %{discard: 1} = Oban.drain_queue(queue: :error_ignorer_test)

      assert [%Error{kind: "Elixir.RuntimeError"}] = Repo.all(Error)
      assert [%Occurrence{context: %{"job.attempt" => 1}}] = Repo.all(Occurrence)
    end
  end

  # The path a crash in a matched route takes (ErrorTracker.Integrations.Phoenix).
  describe "a failed request" do
    test "a server fault is saved" do
      conn = Plug.Test.conn(:get, "/auctions")
      {fault, stacktrace} = raised(%RuntimeError{message: "page fault"})

      ErrorTracker.Integrations.Plug.report_error(conn, {:error, fault}, stacktrace)

      assert [%Error{kind: "Elixir.RuntimeError"}] = Repo.all(Error)
      assert [%Occurrence{context: %{"request.path" => "/auctions"}}] = Repo.all(Occurrence)
    end

    test "an address nobody serves is not saved" do
      conn = Plug.Test.conn(:get, "/no-such-page")

      {missing, stacktrace} =
        raised(Phoenix.Router.NoRouteError.exception(conn: conn, router: AutolaunchWeb.Router))

      ErrorTracker.Integrations.Plug.report_error(conn, {:error, missing}, stacktrace)

      assert Repo.all(Error) == []
    end
  end

  defp raised(exception) do
    raise exception
  rescue
    raised -> {raised, __STACKTRACE__}
  end
end
