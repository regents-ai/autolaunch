defmodule Autolaunch.DurableWork.Runner do
  @moduledoc """
  A small cadence and bounded-dispatch loop for a durable-work handler.

  The runner only polls and dispatches up to `:max_in_flight` items. It has no
  persistence or domain state. Handler processes are monitored and are
  terminated when the runner stops.

  With `:refresh_topic`, a `:chain_refresh` broadcast on that topic
  (`Autolaunch.ChainRefresh`) brings the next poll forward to now, or to the end
  of the gap since the last poll; one that arrives while an item is in flight
  polls again once it finishes.
  """

  use GenServer

  alias Autolaunch.ChainRefresh

  @default_poll_interval_ms 1_000
  @default_max_in_flight 1

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  @impl true
  def init(opts) do
    case validate_options(opts) do
      :ok ->
        state = %{
          handler: Keyword.fetch!(opts, :handler),
          context: Keyword.get(opts, :context),
          poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
          max_in_flight: Keyword.get(opts, :max_in_flight, @default_max_in_flight),
          timer_ref: nil,
          in_flight: %{},
          polled_at: nil,
          again?: false
        }

        subscribe(Keyword.get(opts, :refresh_topic))
        {:ok, state, {:continue, :poll}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, poll_and_schedule(state)}

  @impl true
  def handle_info(:poll, state) do
    {:noreply, poll_and_schedule(%{state | timer_ref: nil})}
  end

  def handle_info(:chain_refresh, state) when map_size(state.in_flight) == 0,
    do: {:noreply, sooner(state)}

  def handle_info(:chain_refresh, state), do: {:noreply, %{state | again?: true}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = drop_in_flight(state, ref)

    if state.again? and map_size(state.in_flight) == 0,
      do: {:noreply, sooner(%{state | again?: false})},
      else: {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)

    Enum.each(state.in_flight, fn {_ref, pid} ->
      Process.exit(pid, :kill)
    end)

    await_down(Map.keys(state.in_flight))
    :ok
  end

  defp poll_and_schedule(state) do
    capacity = state.max_in_flight - map_size(state.in_flight)
    poll = Function.capture(state.handler, :poll, 2)
    items = poll.(state.context, capacity)
    handle = Function.capture(state.handler, :handle, 2)

    unless is_list(items) and length(items) <= capacity do
      raise ArgumentError,
            "durable work handler must return at most #{capacity} items from poll/2"
    end

    state =
      Enum.reduce(items, state, fn item, acc ->
        {pid, ref} = spawn_monitor(fn -> handle.(acc.context, item) end)
        %{acc | in_flight: Map.put(acc.in_flight, ref, pid)}
      end)

    %{
      state
      | timer_ref: Process.send_after(self(), :poll, state.poll_interval_ms),
        polled_at: ChainRefresh.now()
    }
  end

  defp sooner(state) do
    wait = ChainRefresh.wait_ms(state.polled_at)

    if ChainRefresh.later?(state.timer_ref, wait) do
      cancel_timer(state.timer_ref)
      %{state | timer_ref: Process.send_after(self(), :poll, wait)}
    else
      state
    end
  end

  defp subscribe(nil), do: :ok
  defp subscribe(topic), do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic)

  defp drop_in_flight(state, ref), do: %{state | in_flight: Map.delete(state.in_flight, ref)}

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  defp await_down([]), do: :ok

  defp await_down(refs) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
        await_down(List.delete(refs, ref))
    end
  end

  defp validate_options(opts) when is_list(opts) do
    case Keyword.fetch(opts, :handler) do
      {:ok, handler} ->
        with :ok <- validate_handler(handler),
             :ok <- validate_positive(opts, :poll_interval_ms, @default_poll_interval_ms),
             :ok <- validate_positive(opts, :max_in_flight, @default_max_in_flight) do
          validate_topic(Keyword.get(opts, :refresh_topic))
        end

      :error ->
        {:error, {:required_option, :handler}}
    end
  end

  defp validate_options(_opts), do: {:error, :invalid_options}

  defp validate_handler(handler) when is_atom(handler) do
    cond do
      not Code.ensure_loaded?(handler) -> {:error, {:handler_not_loaded, handler}}
      not function_exported?(handler, :poll, 2) -> {:error, {:missing_callback, :poll, 2}}
      not function_exported?(handler, :handle, 2) -> {:error, {:missing_callback, :handle, 2}}
      true -> :ok
    end
  end

  defp validate_handler(_handler), do: {:error, :invalid_handler}

  defp validate_topic(topic) when is_nil(topic) or is_binary(topic), do: :ok
  defp validate_topic(_topic), do: {:error, {:invalid_option, :refresh_topic}}

  defp validate_positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> :ok
      _value -> {:error, {:invalid_option, key}}
    end
  end
end
