defmodule Autolaunch.TestDurableWorkHandler do
  @behaviour Autolaunch.DurableWork.Handler

  @impl true
  def poll(%{owner: owner, queue: queue}, capacity) do
    send(owner, {:durable_poll, __MODULE__, capacity, System.monotonic_time(:millisecond)})

    Agent.get_and_update(queue, fn items ->
      Enum.split(items, capacity)
    end)
  end

  @impl true
  def handle(context, item) do
    update_active(context.active, 1)
    send(context.owner, {:durable_started, __MODULE__, item, self()})

    try do
      if item in Map.get(context, :wait_for_release, []) do
        receive do
          {:release, ^item} -> :ok
        end
      end

      Process.sleep(Map.get(context, :delays, %{}) |> Map.get(item, 0))
      if item in Map.get(context, :crash, []), do: exit(:test_crash)
    after
      update_active(context.active, -1)
    end

    send(context.owner, {:durable_finished, __MODULE__, item})
  end

  defp update_active(agent, delta) do
    Agent.update(agent, fn %{current: current, maximum: maximum} ->
      current = current + delta
      %{current: current, maximum: max(maximum, current)}
    end)
  end
end

defmodule Autolaunch.OtherDurableWorkHandler do
  @behaviour Autolaunch.DurableWork.Handler

  @impl true
  def poll(%{owner: owner, queue: queue}, capacity) do
    send(owner, {:other_durable_poll, __MODULE__, capacity})

    Agent.get_and_update(queue, fn items ->
      Enum.split(items, capacity)
    end)
  end

  @impl true
  def handle(%{owner: owner}, item) do
    send(owner, {:other_durable_started, __MODULE__, item, self()})
    send(owner, {:other_durable_finished, __MODULE__, item})
  end
end
