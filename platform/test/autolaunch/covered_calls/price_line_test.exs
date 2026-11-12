defmodule Autolaunch.CoveredCalls.PriceLineTest do
  @moduledoc """
  The reader of a market's last 30 days: its first read walks the feed back to
  the price in force 30 days ago and thins the rest to at most 240 points, the
  newest kept exact; each later read asks only for the rounds since the newest
  held; a failed read keeps the points and marks them, and no line is drawn
  from them until a read succeeds again.
  """
  use ExUnit.Case, async: false

  alias Autolaunch.CoveredCalls.PriceLine
  alias Autolaunch.{CoveredCallsChain, SharedReading}

  @now CoveredCallsChain.now()
  @month 30 * 86_400
  @key PriceLine.key("AMZNc")

  setup do
    :ok = SharedReading.delete(@key)
    on_exit(fn -> SharedReading.delete(@key) end)
  end

  test "the first read keeps the price in force 30 days ago and at most 240 points, the newest exact" do
    # A round every two hours for 33 days, then the latest half an hour ago.
    history = for hour <- 793..3//-2, do: {@now - hour * 3_600, 25_000_000_000 + hour * 1_000_000}
    CoveredCallsChain.install(%{history: history, price: 25_400_000_000, price_at: @now - 1_800})
    read_once()

    assert {:ok, %{reading: %{decimals: 8, points: points}, degraded?: false}} =
             SharedReading.fetch(@key)

    assert length(points) <= 240
    assert List.last(points) == {@now - 1_800, 25_400_000_000}
    assert points == Enum.sort_by(points, &elem(&1, 0))

    # The round in force when the 30 days start, then only rounds inside them.
    in_force = history |> Enum.filter(fn {at, _} -> at <= @now - @month end) |> List.last()
    assert [^in_force, {second_at, _answer} | _rest] = points
    assert second_at > @now - @month

    # In dollars, the line starts 30 days before its newest point.
    line = PriceLine.line("AMZNc")
    assert hd(line) == [@now - 1_800 - @month, elem(in_force, 1) / 100_000_000]
    assert List.last(line) == [@now - 1_800, 254.0]
  end

  test "a later read adds only the rounds after the newest held" do
    history = for hour <- 56..10//-2, do: {@now - hour * 3_600, 25_000_000_000}
    CoveredCallsChain.install(%{history: history, price_at: @now - 8 * 3_600})
    reader = read_once()
    {:ok, %{reading: %{points: held}}} = SharedReading.fetch(@key)

    # Nothing newer: the reading stays as it was.
    read_again(reader)
    assert {:ok, %{reading: %{points: ^held}}} = SharedReading.fetch(@key)

    # Two new rounds, each further from the last than the line's thinning
    # reaches, and the old rounds reading differently now: only the new are taken.
    CoveredCallsChain.put(%{
      history:
        Enum.map(history, fn {at, _answer} -> {at, 1} end) ++
          [{@now - 8 * 3_600, 25_400_000_000}, {@now - 4 * 3_600, 25_500_000_000}],
      price: 25_600_000_000,
      price_at: @now - 60
    })

    read_again(reader)

    assert {:ok, %{reading: %{points: points}, degraded?: false}} = SharedReading.fetch(@key)
    assert points == held ++ [{@now - 4 * 3_600, 25_500_000_000}, {@now - 60, 25_600_000_000}]
  end

  test "a failed read keeps the points, marked, and no line is drawn until one succeeds" do
    history = for hour <- 48..2//-2, do: {@now - hour * 3_600, 25_000_000_000}
    CoveredCallsChain.install(%{history: history, price_at: @now - 3_600})
    reader = read_once()
    {:ok, %{reading: held}} = SharedReading.fetch(@key)
    line = PriceLine.line("AMZNc")
    assert [_, _ | _] = line

    CoveredCallsChain.put(%{history: history, price_at: @now - 3_600, unreadable: true})
    read_again(reader)

    assert {:ok, %{reading: ^held, degraded?: true}} = SharedReading.fetch(@key)
    assert PriceLine.line("AMZNc") == nil

    CoveredCallsChain.put(%{history: history, price_at: @now - 3_600})
    read_again(reader)

    assert {:ok, %{reading: ^held, degraded?: false}} = SharedReading.fetch(@key)
    assert PriceLine.line("AMZNc") == line
  end

  test "one reader for each market while covered calls are on, none while they are off" do
    assert PriceLine.children() == []
    CoveredCallsChain.install()
    assert [%{id: {PriceLine, "AMZNc"}}] = PriceLine.children()
  end

  # The market's reader, started as the site starts it, its first read done.
  defp read_once do
    [child] = PriceLine.children()
    reader = start_supervised!(child)
    :sys.get_state(reader)
    reader
  end

  # What the reader does five minutes after its last read finished.
  defp read_again(reader) do
    send(reader, :read)
    :sys.get_state(reader)
  end
end
