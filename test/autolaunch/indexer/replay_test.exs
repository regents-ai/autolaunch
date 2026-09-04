defmodule Autolaunch.Indexer.ReplayTest do
  @moduledoc """
  What re-reading a range the ledger already holds is allowed to do.

  Exact evidence replays as a no-op, disagreeing evidence under the same identity
  fails the whole transaction closed, and neither a finalized header nor an
  orphaned one is ever rewritten by a later pass. A fork the ledger has already
  abandoned is never revived: a provider that oscillates between two views — one
  load-balanced node behind another during a reorg — stops the pass rather than
  advancing the cursor over headers no consumer can see.
  """

  use Autolaunch.IndexerCase, async: false

  alias Autolaunch.TestAutolaunchIndexerChainClient, as: Endpoint

  @auction "0x00000000000000000000000000000000000000aa"
  @late "0x00000000000000000000000000000000000000bb"

  setup do
    start_endpoint(chain(ingested(), safe: 12, finalized: 10))
    {:ok, _source} = admit(@auction, 10)
    assert {:ok, _range} = pass()
    :ok
  end

  test "an exact replay writes nothing new and keeps the finality it already granted" do
    before_blocks = stored_blocks()
    before_logs = stored_logs()
    assert finalized() == [10]

    rewind_with_late_source()
    assert {:ok, _range} = pass()

    assert Enum.map(stored_blocks(), &{&1.id, &1.canonical, &1.finalized}) ==
             Enum.map(before_blocks, &{&1.id, &1.canonical, &1.finalized})

    assert Enum.map(stored_logs(), & &1.id) == Enum.map(before_logs, & &1.id)
    assert cursor().next_block_to_fetch == 13
  end

  test "same-key evidence that disagrees aborts the range and commits none of it" do
    rewind_with_late_source()

    conflicting =
      10..13
      |> blocks()
      |> emit(11, [%{index: 0, address: @auction, data: "0xdeadbeef"}])

    Endpoint.script(chain(conflicting, safe: 13, finalized: 10))

    assert pass() == {:error, {:log_conflict, 0}}

    # Block 13 was inserted before the conflicting log in the same transaction,
    # so its absence is what proves the rollback left nothing behind.
    assert Enum.map(stored_blocks(), & &1.block_number) == [10, 11, 12]
    assert Enum.map(stored_logs(), & &1.data) == ["0x"]
    assert cursor().next_block_to_fetch == 10
  end

  test "a reorg keeps both placements and re-inclusion lands as its own row" do
    reorged = 10..13 |> blocks(fork(11..13, "b")) |> emit(11, [%{index: 0, address: @auction}])
    Endpoint.script(chain(reorged, safe: 13, finalized: 10))

    assert {:ok, _rewind} = pass()
    assert cursor().next_block_to_fetch == 11
    assert orphaned() == [11, 12]

    assert {:ok, _range} = pass()
    assert cursor().next_block_to_fetch == 14

    # One transaction, re-included under a new block hash: a second row, while
    # the former placement survives as evidence beneath a noncanonical block.
    assert [orphan, included] =
             stored_logs()
             |> Enum.filter(&(&1.transaction_hash == transaction_hash(11, 0)))
             |> Enum.sort_by(&(&1.block_hash == block_hash(11, "b")))

    assert orphan.block_hash == block_hash(11)
    assert included.block_hash == block_hash(11, "b")
    refute canonical?(orphan.block_hash)
    assert canonical?(included.block_hash)
  end

  test "an oscillating provider cannot advance over an abandoned fork, and the stored one can" do
    reorged = 10..13 |> blocks(fork(11..13, "b")) |> emit(11, [%{index: 0, address: @auction}])
    Endpoint.script(chain(reorged, safe: 13, finalized: 10))

    assert {:ok, _rewind} = pass()
    assert {:ok, _range} = pass()
    assert cursor().next_block_to_fetch == 14
    assert orphaned() == [11, 12]

    # The other node behind the load balancer still serves the fork this ledger
    # abandoned. Its headers are stored evidence of an orphan, so the pass stops
    # instead of walking back into them.
    before_blocks = stored_blocks()
    Endpoint.script(chain(ingested(), safe: 14, finalized: 10))

    assert pass() == {:error, {:noncanonical_replay, 12}}

    assert Enum.map(stored_blocks(), &{&1.block_hash, &1.canonical, &1.finalized}) ==
             Enum.map(before_blocks, &{&1.block_hash, &1.canonical, &1.finalized})

    assert cursor().next_block_to_fetch == 14

    # Back on the fork the ledger holds as canonical, the same position advances.
    Endpoint.script(chain(blocks(10..15, fork(11..15, "b")), safe: 15, finalized: 10))

    assert {:ok, _range} = pass()
    assert cursor().next_block_to_fetch == 16
    assert canonical?(block_hash(15, "b"))
  end

  defp ingested, do: 10..14 |> blocks() |> emit(11, [%{index: 0, address: @auction}])

  # A second address behind the cursor is the only way a caller pulls the ledger
  # back over evidence it already holds.
  defp rewind_with_late_source do
    assert {:ok, _source} = admit(@late, 10)
    assert cursor().next_block_to_fetch == 10
  end
end
