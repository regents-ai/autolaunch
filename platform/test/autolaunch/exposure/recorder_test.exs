defmodule Autolaunch.Exposure.RecorderTest do
  @moduledoc """
  The price recorder keeps a series moving without anyone pressing: once a
  price may be recorded it sends `record`, and once the chain has mined that,
  `settle`; it never sends a series a second transaction while the chain has
  not settled the first; a price missed past its window ends the series; and
  a series that has ended is not looked at again.
  """

  use Autolaunch.DataCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.Exposure.{RecorderTransaction, Recording}
  alias Autolaunch.ExposureChain

  # Anvil's public test account 9, from the well-known "test … junk" mnemonic.
  @key "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"
  @actor %System{}
  @series ExposureChain.series()
  @oracle ExposureChain.oracle()
  @boundaries ExposureChain.boundaries()
  @wad ExposureChain.wad()

  setup do
    ExposureChain.install()
    previous = Application.get_env(:autolaunch, :exposure_recorder_key)
    Application.put_env(:autolaunch, :exposure_recorder_key, @key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :exposure_recorder_key, previous),
        else: Application.delete_env(:autolaunch, :exposure_recorder_key)
    end)

    Autolaunch.Exposure.Record.follow()
    [recording] = Ash.read!(Recording, actor: @actor)
    %{recording: recording}
  end

  # The third price (Mon 2 Nov's close), an hour and a minute after its time.
  defp third_price_due, do: ExposureChain.put(%{now: Enum.at(@boundaries, 2) + 3_660})

  defp run(recording) do
    recording
    |> Ash.Changeset.for_update(:record, %{}, actor: @actor)
    |> Ash.update!()
  end

  # A signed transaction carries the contract it calls and the function's selector.
  defp calls?(raw, contract, function),
    do:
      String.contains?(raw, String.trim_leading(contract, "0x")) and
        String.contains?(raw, String.trim_leading(RegentChain.Call.selector(function), "0x"))

  defp transactions, do: Ash.read!(RecorderTransaction, actor: @actor)

  test "following the listed series adds each once", %{recording: recording} do
    Autolaunch.Exposure.Record.follow()
    assert [%{series: @series, state: :running}] = Ash.read!(Recording, actor: @actor)
    assert recording.series == @series
  end

  test "before a price may be recorded, nothing is sent", %{recording: recording} do
    run(recording)
    assert ExposureChain.broadcasts() == []
  end

  test "a due price is recorded, waited for, then applied", %{recording: recording} do
    third_price_due()
    run(recording)

    assert [record] = ExposureChain.broadcasts()
    assert calls?(record, @oracle, "record(uint64,bool,uint64)")
    assert [%{step: :record, state: :signed}] = transactions()

    # Not mined yet: the series is sent nothing more.
    run(recording)
    assert length(ExposureChain.broadcasts()) == 1

    # Mined, and the oracle now holds the price: the next run applies it.
    ExposureChain.mine("0x1")

    ExposureChain.put(%{
      now: Enum.at(@boundaries, 2) + 3_660,
      recorded: %{Enum.at(@boundaries, 2) => 257 * @wad}
    })

    run(recording)

    assert [_record, settle] = ExposureChain.broadcasts()
    assert calls?(settle, @series, "settle()")

    assert Enum.sort(Enum.map(transactions(), &{&1.step, &1.state})) ==
             [{:record, :mined}, {:settle, :signed}]
  end

  test "a price the feed can no longer give ends the series once its window has passed",
       %{recording: recording} do
    # A week and a day after the third price, with no feed round in the 84 hours before it.
    ExposureChain.put(%{
      now: Enum.at(@boundaries, 2) + 8 * 86_400,
      rounds: [{Enum.at(@boundaries, 2) - 5 * 86_400, 25_000_000_000}]
    })

    run(recording)

    assert [ending] = ExposureChain.broadcasts()
    assert calls?(ending, @series, "endOnMissingPrint()")
    assert [%{step: :end}] = transactions()
  end

  test "a price the feed can't give is waited on until its window has passed", %{
    recording: recording
  } do
    third = Enum.at(@boundaries, 2)

    ExposureChain.put(%{
      now: third + 3_660,
      rounds: [{third - 5 * 86_400, 25_000_000_000}]
    })

    run(recording)
    assert ExposureChain.broadcasts() == []
  end

  test "a price recorded after its window ends the series", %{recording: recording} do
    third = Enum.at(@boundaries, 2)

    ExposureChain.put(%{
      now: third + 8 * 86_400,
      recorded: %{third => 257 * @wad},
      late: %{third => third + 7 * 86_400 + 60}
    })

    run(recording)
    assert [ending] = ExposureChain.broadcasts()
    assert calls?(ending, @series, "endOnMissingPrint()")
  end

  test "a series the site no longer lists is not followed any more", %{recording: recording} do
    stray = %{recording | series: "0x1234567890123456789012345678901234567890"}

    {:ok, stray} =
      Recording
      |> Ash.Changeset.for_create(:add, %{chain_id: recording.chain_id, series: stray.series},
        actor: @actor
      )
      |> Ash.create()

    assert %{state: :ended} = run(stray)
    assert ExposureChain.broadcasts() == []
  end

  test "a series that has ended is marked so and not looked at again", %{recording: recording} do
    ExposureChain.put(%{status: 2, end_reason: 1})
    assert %{state: :ended} = run(recording)
    assert ExposureChain.broadcasts() == []
  end
end
