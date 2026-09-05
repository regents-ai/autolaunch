defmodule Autolaunch.Accounts.BootstrapRateLimiter do
  @moduledoc """
  The anonymous session bootstrap budget, held in one fixed window per key.

  The bound is per node and best effort, not a global hard cap: with N
  application instances one client can spend up to N × limit in a window. The
  upgrade trigger is before the write path scales horizontally: replace this
  with a distributed, shared-state budget.

  Concurrent identical requests may transiently 429 and self-heal on retry.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec admit(term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def admit(key, limit, window_seconds) do
    table = ensure_table()
    bucket = System.monotonic_time(:second) |> div(window_seconds)
    sweep_expired(table, bucket, window_seconds)
    increment(table, {window_seconds, key}, bucket, limit)
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp increment(table, key, bucket, limit) do
    case :ets.lookup(table, key) do
      [] ->
        insert_first(table, key, bucket, limit)

      [{^key, ^bucket, _count}] ->
        increment_current(table, key, limit)

      [{^key, old_bucket, count}] ->
        reset_expired(table, key, old_bucket, count, bucket, limit)
    end
  end

  defp insert_first(table, key, bucket, limit) do
    if :ets.insert_new(table, {key, bucket, 1}),
      do: :ok,
      else: increment(table, key, bucket, limit)
  end

  defp increment_current(table, key, limit) do
    if :ets.update_counter(table, key, {3, 1}) <= limit,
      do: :ok,
      else: {:error, :rate_limited}
  end

  defp reset_expired(table, key, old_bucket, count, bucket, limit) do
    replacement = [{{key, old_bucket, count}, [], [{{key, bucket, 1}}]}]

    if :ets.select_replace(table, replacement) == 1,
      do: :ok,
      else: increment(table, key, bucket, limit)
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
