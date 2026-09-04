defmodule Autolaunch.DurableWork.RunnerTest do
  use ExUnit.Case, async: false

  alias Autolaunch.DurableWork.Runner

  test "polls on cadence and bounds concurrent handler invocations" do
    owner = self()
    queue = start_agent([:slow, :fast])
    active = start_agent(%{current: 0, maximum: 0})

    runner =
      start_runner(
        handler: Autolaunch.TestDurableWorkHandler,
        context: %{
          owner: owner,
          queue: queue,
          active: active,
          wait_for_release: [:slow, :fast]
        },
        poll_interval_ms: 15,
        max_in_flight: 2
      )

    assert_receive {:durable_poll, Autolaunch.TestDurableWorkHandler, 2, first_poll}, 200
    assert_receive {:durable_started, Autolaunch.TestDurableWorkHandler, :slow, slow_task}, 200
    assert_receive {:durable_started, Autolaunch.TestDurableWorkHandler, :fast, fast_task}, 200
    assert Agent.get(active, & &1) == %{current: 2, maximum: 2}

    assert_receive {:durable_poll, Autolaunch.TestDurableWorkHandler, 0, second_poll}, 200
    assert_receive {:durable_poll, Autolaunch.TestDurableWorkHandler, 0, third_poll}, 200

    assert second_poll - first_poll >= 10
    assert third_poll - second_poll >= 10

    send(fast_task, {:release, :fast})
    assert_receive {:durable_finished, Autolaunch.TestDurableWorkHandler, :fast}, 200
    assert Agent.get(active, & &1) == %{current: 1, maximum: 2}

    send(slow_task, {:release, :slow})
    assert_receive {:durable_finished, Autolaunch.TestDurableWorkHandler, :slow}, 200
    assert Agent.get(active, & &1) == %{current: 0, maximum: 2}

    Runner.stop(runner)
  end

  test "runs two unrelated handlers independently" do
    owner = self()
    first_queue = start_agent([:first])
    second_queue = start_agent([:second])

    first_runner =
      start_runner(
        handler: Autolaunch.TestDurableWorkHandler,
        context: %{
          owner: owner,
          queue: first_queue,
          active: start_agent(%{current: 0, maximum: 0})
        },
        poll_interval_ms: 20,
        max_in_flight: 1
      )

    second_runner =
      start_runner(
        handler: Autolaunch.OtherDurableWorkHandler,
        context: %{owner: owner, queue: second_queue},
        poll_interval_ms: 20,
        max_in_flight: 1
      )

    assert_receive {:durable_started, Autolaunch.TestDurableWorkHandler, :first, _task}, 200

    assert_receive {:other_durable_started, Autolaunch.OtherDurableWorkHandler, :second, _task},
                   200

    assert_receive {:durable_finished, Autolaunch.TestDurableWorkHandler, :first}, 200
    assert_receive {:other_durable_finished, Autolaunch.OtherDurableWorkHandler, :second}, 200

    Runner.stop(first_runner)
    Runner.stop(second_runner)
  end

  test "capacity one invokes handlers in order and restarts under the same name" do
    owner = self()
    runner_name = :durable_work_runner_test
    queue = start_agent([:first, :crashed, :third])
    active = start_agent(%{current: 0, maximum: 0})

    runner =
      start_runner(
        name: runner_name,
        handler: Autolaunch.TestDurableWorkHandler,
        context: %{
          owner: owner,
          queue: queue,
          active: active,
          wait_for_release: [:crashed, :third],
          crash: [:crashed]
        },
        poll_interval_ms: 15,
        max_in_flight: 1
      )

    assert Process.whereis(runner_name) == runner
    assert_receive {:durable_poll, Autolaunch.TestDurableWorkHandler, 1, _first_poll}, 200

    assert_receive {:durable_started, Autolaunch.TestDurableWorkHandler, :first, _first_task},
                   200

    assert_receive {:durable_finished, Autolaunch.TestDurableWorkHandler, :first}, 200

    assert_receive {:durable_poll, Autolaunch.TestDurableWorkHandler, 1, _crashed_poll}, 200

    assert_receive {:durable_started, Autolaunch.TestDurableWorkHandler, :crashed, crashed_task},
                   200

    assert Agent.get(active, & &1) == %{current: 1, maximum: 1}
    assert_receive {:durable_poll, Autolaunch.TestDurableWorkHandler, 0, _blocked_poll}, 200
    refute_receive {:durable_started, Autolaunch.TestDurableWorkHandler, :third, _task}, 20

    send(crashed_task, {:release, :crashed})
    refute_receive {:durable_finished, Autolaunch.TestDurableWorkHandler, :crashed}, 20
    assert_receive {:durable_poll, Autolaunch.TestDurableWorkHandler, 1, _reopened_poll}, 200

    assert_receive {:durable_started, Autolaunch.TestDurableWorkHandler, :third, third_task},
                   200

    assert Agent.get(active, & &1) == %{current: 1, maximum: 1}

    assert :ok = Runner.stop(runner)
    refute Process.alive?(runner)
    refute Process.alive?(third_task)
    assert Process.whereis(runner_name) == nil

    restarted_queue = start_agent([:restarted])

    restarted =
      start_runner(
        name: runner_name,
        handler: Autolaunch.OtherDurableWorkHandler,
        context: %{owner: owner, queue: restarted_queue},
        poll_interval_ms: 20,
        max_in_flight: 1
      )

    assert Process.whereis(runner_name) == restarted

    assert_receive {:other_durable_started, Autolaunch.OtherDurableWorkHandler, :restarted,
                    _task},
                   200

    assert_receive {:other_durable_finished, Autolaunch.OtherDurableWorkHandler, :restarted}, 200
    Runner.stop(restarted)
    assert Process.whereis(runner_name) == nil
  end

  defp start_agent(value) do
    {:ok, agent} = Agent.start_link(fn -> value end)
    agent
  end

  defp start_runner(opts) do
    {:ok, runner} = Runner.start_link(opts)

    on_exit(fn ->
      if Process.alive?(runner), do: Runner.stop(runner)
    end)

    runner
  end
end
