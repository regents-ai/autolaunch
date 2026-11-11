defmodule Autolaunch.SharedReadingTest do
  # Every reading offered to the figure every visitor sees alike reports its size
  # against its kind's limit, so one growing towards it shows before it is refused.
  use ExUnit.Case, async: false

  alias Autolaunch.SharedReading

  @key {:chain_head, "size-test"}

  setup do
    on_exit(fn -> SharedReading.delete(@key) end)
  end

  test "every reading offered reports its size against its kind's limit, refused ones too" do
    test = self()

    :telemetry.attach(
      "shared-reading-size-test",
      [:autolaunch, :shared_reading, :size],
      fn _, size, %{kind: kind}, _ -> send(test, {kind, size}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("shared-reading-size-test") end)

    big = String.duplicate("9", 65)
    assert :ok = SharedReading.put(@key, 41)
    assert {:error, :too_large} = SharedReading.put(@key, big)

    assert_received {:chain_head, %{bytes: small, limit: 64}} when small <= 64
    assert_received {:chain_head, %{bytes: large, limit: 64}} when large > 64
  end
end
