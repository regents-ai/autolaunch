defmodule Autolaunch.Indexer.FinalityTest do
  @moduledoc """
  What the provider's exact finalized hash is, and is not, enough to promote.

  Protects CONNECTED_FINALITY_ONLY. The finalized hash names one stored block;
  everything promoted with it has to be reachable from that block through stored
  parent hashes. A canonical segment sitting at an obviously promotable height
  with no stored link to the finalized evidence is not final and is left alone,
  however long it waits, and it becomes final the moment the missing header is
  stored. Growth is bounded at both ends, so a deep backfill is caught up over
  ordinary later passes rather than in one unbounded promotion.
  """

  use Autolaunch.IndexerCase, async: false

  alias Autolaunch.TestAutolaunchIndexerChainClient, as: Endpoint

  @auction "0x00000000000000000000000000000000000000aa"
  @late "0x00000000000000000000000000000000000000bb"

  test "a segment with no stored link to the finalized block waits, and lands when the link does" do
    start_endpoint(chain(blocks(1..20), safe: 12, finalized: 12))
    assert {:ok, _source} = admit(@auction, 10)

    assert {:ok, _range} = pass()
    assert finalized() == [10, 11, 12]

    # A late address opens the ledger at height 1, so the pass that follows
    # stores a whole segment that stops one header short of the finalized one.
    assert {:ok, _source} = admit(@late, 1)
    assert {:ok, _backfill} = pass()

    assert Enum.map(stored_blocks(), & &1.block_number) == Enum.to_list(1..8) ++ [10, 11, 12]
    assert cursor().next_block_to_fetch == 9

    # Every one of those heights is below the finalized block and canonical, and
    # not one of them is final: height alone proves nothing.
    assert finalized() == [10, 11, 12]

    # Storing the one header that bridges the gap makes the whole run reachable,
    # and it is promoted a bound at a time rather than all at once.
    assert {:ok, _bridged} = pass()
    assert finalized() == Enum.to_list(2..12)

    assert {:ok, _promotion} = pass()
    assert finalized() == Enum.to_list(1..12)
  end

  test "promotion stops at the exact finalized evidence and resumes when it moves" do
    start_endpoint(chain(blocks(1..30), safe: 20, finalized: 12))
    assert {:ok, _source} = admit(@auction, 10)

    assert {:ok, _range} = pass()
    assert Enum.map(stored_blocks(), & &1.block_number) == Enum.to_list(10..17)
    assert finalized() == [10, 11, 12]

    assert {:ok, _range} = pass()
    assert Enum.map(stored_blocks(), & &1.block_number) == Enum.to_list(10..20)

    # Eight more canonical heights are stored above the finalized block. The
    # provider has called none of them final, so neither has the ledger.
    assert finalized() == [10, 11, 12]

    Endpoint.script(chain(blocks(1..30), safe: 20, finalized: 16))
    assert {:ok, _promotion} = pass()

    assert finalized() == Enum.to_list(10..16)
  end

  test "a finalized hash the ledger does not hold as canonical promotes nothing" do
    start_endpoint(chain(blocks(1..20), safe: 12, finalized: 9))
    assert {:ok, _source} = admit(@auction, 10)

    assert {:ok, _range} = pass()
    assert Enum.map(stored_blocks(), & &1.block_number) == [10, 11, 12]
    assert finalized() == []

    # The provider now calls a height this ledger does hold final, but names it
    # by a hash from another fork. The height is right and the evidence is not.
    Endpoint.script(chain(blocks(1..20, fork(12..20, "b")), safe: 12, finalized: 12))

    assert {:ok, _promotion} = pass()
    assert finalized() == []

    # The same height under the hash the ledger actually stores anchors the run
    # beneath it, and only then.
    Endpoint.script(chain(blocks(1..20), safe: 12, finalized: 12))

    assert {:ok, _promotion} = pass()
    assert finalized() == [10, 11, 12]
  end
end
