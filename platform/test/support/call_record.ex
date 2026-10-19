defmodule Autolaunch.CallRecord do
  @moduledoc """
  The calls made into chosen functions while a test function runs, read with
  the runtime's own tracing, so a test can show what the code under test did
  or never did without any hook in it. Only a synchronous case may use it: a
  trace pattern is global.
  """

  import ExUnit.Assertions

  @type event :: {:call | :return, {module(), atom(), arity()}, pid()}

  @doc """
  Runs `fun` while recording every call, and each call's return, that the
  processes `who` names (a pid, or `:all`) make into `patterns` (such as
  `{Vix.Nif, :_, :_}`). Answers `{result, events}`, the events in the order
  they happened.
  """
  @spec during(pid() | :all, [{module(), atom(), arity() | :_}], (-> result)) ::
          {result, [event()]}
        when result: term()
  def during(who, patterns, fun) do
    Enum.each(patterns, fn {module, _function, _arity} -> Code.ensure_loaded!(module) end)
    Enum.each(patterns, &:erlang.trace_pattern(&1, [{:_, [], [{:return_trace}]}], [:global]))
    collector = spawn_link(fn -> collect([]) end)
    :erlang.trace(who, true, [:call, :strict_monotonic_timestamp, {:tracer, collector}])

    result =
      try do
        fun.()
      after
        :erlang.trace(who, false, [:call])
        Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:global]))
      end

    {result, collected(who, collector)}
  end

  @doc "The calls alone, as `{module, function, arity}`, in order."
  @spec calls([event()]) :: [{module(), atom(), arity()}]
  def calls(events), do: for({:call, mfa, _pid} <- events, do: mfa)

  defp collect(events) do
    receive do
      {:trace_ts, pid, :call, {module, function, arguments}, at} ->
        collect([{at, {:call, {module, function, length(arguments)}, pid}} | events])

      {:trace_ts, pid, :return_from, mfa, _value, at} ->
        collect([{at, {:return, mfa, pid}} | events])

      {:events, asker} ->
        send(asker, {:events, events |> Enum.sort() |> Enum.map(&elem(&1, 1))})
    end
  end

  # Every trace message has reached the collector before it is asked.
  defp collected(who, collector) do
    reference = :erlang.trace_delivered(who)
    assert_receive {:trace_delivered, _who, ^reference}, 5_000
    send(collector, {:events, self()})
    assert_receive {:events, events}, 5_000
    events
  end
end
