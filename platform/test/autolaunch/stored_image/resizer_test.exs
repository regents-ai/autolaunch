defmodule Autolaunch.StoredImage.ResizerTest do
  @moduledoc """
  A sized copy decodes the whole original, so copies are made one at a time
  however many are asked for at once, and a request whose caller has stopped
  waiting is not made at all. The calls into libvips are read with the
  runtime's tracing (`Autolaunch.CallRecord`).
  """
  use ExUnit.Case, async: false

  alias Autolaunch.CallRecord
  alias Autolaunch.StoredImage.Resizer
  alias Vix.Vips.Operation

  setup_all do
    # A 2,000 pixel square of noise: a PNG has no smaller decode to fall back
    # on, so each copy takes long enough that two side by side would overlap.
    {:ok, noise} = Operation.gaussnoise(2_000, 2_000)
    {:ok, png} = Operation.pngsave_buffer(noise, compression: 1)
    %{png: png}
  end

  test "RESIZE_ONE_AT_A_TIME: two copies asked for at once are made one after the other",
       %{png: png} do
    resizer = Process.whereis(Resizer)

    # Both requests wait in the resizer's mailbox before either is made.
    :ok = :sys.suspend(resizer)

    {results, events} =
      try do
        CallRecord.during(:all, [{Operation, :thumbnail_buffer, :_}], fn ->
          first = Task.async(fn -> Resizer.webp(png, 96) end)
          second = Task.async(fn -> Resizer.webp(png, 160) end)
          queued(resizer, 2)
          :sys.resume(resizer)
          {Task.await(first, 15_000), Task.await(second, 15_000)}
        end)
      after
        # Resuming a running process changes nothing.
        :sys.resume(resizer)
      end

    assert {{:ok, <<"RIFF", _::binary>>}, {:ok, <<"RIFF", _::binary>>}} = results

    copy = {Operation, :thumbnail_buffer, 3}

    assert [
             {:call, ^copy, ^resizer},
             {:return, ^copy, ^resizer},
             {:call, ^copy, ^resizer},
             {:return, ^copy, ^resizer}
           ] = events
  end

  test "RESIZE_SKIPS_A_CALLER_THAT_GAVE_UP: a request past its caller's deadline is not made",
       %{png: png} do
    now = System.monotonic_time(:millisecond)

    {waiting, made} =
      CallRecord.during(:all, [{Operation, :_, :_}], fn ->
        GenServer.call(Resizer, {:webp, png, 96, now + 10_000})
      end)

    assert {:ok, <<"RIFF", _::binary>>} = waiting
    assert {Operation, :thumbnail_buffer, 3} in CallRecord.calls(made)

    {gave_up, skipped} =
      CallRecord.during(:all, [{Operation, :_, :_}], fn ->
        GenServer.call(Resizer, {:webp, png, 96, now - 1})
      end)

    assert gave_up == :error
    assert skipped == []
  end

  defp queued(pid, count) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, ^count} ->
        :ok

      _fewer ->
        Process.sleep(5)
        queued(pid, count)
    end
  end
end
