defmodule Autolaunch.ErrorIgnorerTest do
  use Autolaunch.DataCase, async: true

  alias Autolaunch.Repo

  defp saved, do: Repo.aggregate(ErrorTracker.Error, :count, prefix: "autolaunch_app")

  defp report(context) do
    ErrorTracker.report(
      %RuntimeError{message: "timeout"},
      [{__MODULE__, :perform, 2, []}],
      context
    )
  end

  test "JOB_FAILURE_WITH_A_TRY_LEFT_IS_NOT_SAVED: only a job's last failed try is saved" do
    assert :noop = report(%{state: :failure})
    assert saved() == 0

    assert %ErrorTracker.Occurrence{} = report(%{state: :exhausted})
    assert saved() == 1
  end

  test "a server fault outside a job is saved, and a visitor's bad request is not" do
    assert %ErrorTracker.Occurrence{} = report(%{})

    assert :noop =
             ErrorTracker.report(Ash.Error.Invalid.exception(errors: []), [
               {__MODULE__, :perform, 2, []}
             ])

    assert saved() == 1
  end
end
