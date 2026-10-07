defmodule Autolaunch.Accounts.RequestRateLimiter do
  @moduledoc """
  Per-client fixed-window budgets for the public API, the health check and the
  share pictures. Every answer carries what is left of the window, so a
  response can tell the caller how many requests remain and when the window
  resets.

  This is a per-instance best-effort bound, not a global hard cap. With N
  application instances, a client can spend up to N × limit in one window.
  Replace this with a distributed budget before horizontal scaling.
  """

  use GenServer

  @table __MODULE__

  @type budget :: %{
          limit: pos_integer(),
          remaining: non_neg_integer(),
          reset: pos_integer(),
          window: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec admit(term(), pos_integer(), pos_integer()) ::
          {:ok, budget()} | {:error, :rate_limited, budget()}
  def admit(key, limit, window_seconds) do
    table = ensure_table()
    now = System.monotonic_time(:second)
    bucket = Integer.floor_div(now, window_seconds)
    sweep_expired(table, bucket, window_seconds)
    count = increment(table, {window_seconds, key}, bucket)

    budget = %{
      limit: limit,
      remaining: max(limit - count, 0),
      reset: (bucket + 1) * window_seconds - now,
      window: window_seconds
    }

    if count <= limit, do: {:ok, budget}, else: {:error, :rate_limited, budget}
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp increment(table, key, bucket) do
    case :ets.lookup(table, key) do
      [] -> insert_first(table, key, bucket)
      [{^key, ^bucket, _count}] -> :ets.update_counter(table, key, {3, 1})
      [{^key, old_bucket, count}] -> reset_expired(table, key, old_bucket, count, bucket)
    end
  end

  defp insert_first(table, key, bucket) do
    if :ets.insert_new(table, {key, bucket, 1}),
      do: 1,
      else: increment(table, key, bucket)
  end

  defp reset_expired(table, key, old_bucket, count, bucket) do
    replacement = [{{key, old_bucket, count}, [], [{{key, bucket, 1}}]}]

    if :ets.select_replace(table, replacement) == 1,
      do: 1,
      else: increment(table, key, bucket)
  end

  defp sweep_expired(table, bucket, window_seconds) do
    if :ets.insert_new(table, {{:sweep, window_seconds, bucket}, true}) do
      :ets.select_delete(table, [
        {{{window_seconds, :"$1"}, :"$2", :"$3"}, [{:<, :"$2", bucket}], [true]}
      ])

      :ets.select_delete(table, [
        {{{:sweep, window_seconds, :"$1"}, :"$2"}, [{:<, :"$1", bucket}], [true]}
      ])
    end

    :ok
  end

  defp ensure_table do
    GenServer.call(__MODULE__, :table)
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, @table, state}
end
