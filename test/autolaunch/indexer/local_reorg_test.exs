defmodule Autolaunch.Indexer.LocalReorgTest do
  @moduledoc """
  Which stored rows a reorg is allowed to retire, and when it refuses outright.

  Protects LOCAL_REORG_ONLY. A rewind judges one thing: the run of canonical
  rows that starts at the height just above the chosen ancestor and climbs by
  stored parent links. What sits above a gap in that run is not part of this
  reorg and is left exactly as it was, including its finality — an unrelated
  finalized segment higher up neither blocks the local decision nor is touched
  by it. A run longer than the bound is refused whole rather than half-applied,
  and refusing writes nothing at all.
  """

  use Autolaunch.IndexerCase, async: false

  alias Autolaunch.Indexer.Handler
  alias Autolaunch.TestAutolaunchIndexerChainClient, as: Endpoint

  @auction "0x00000000000000000000000000000000000000aa"
  @late "0x00000000000000000000000000000000000000bb"

  test "a rewind retires the run at the ancestor and leaves a finalized segment above a gap" do
    start_endpoint(chain(blocks(1..20), safe: 12, finalized: 12))
    assert {:ok, _source} = admit(@auction, 10)

    assert {:ok, _range} = pass()
    assert finalized() == [10, 11, 12]

    # A late address opens the ledger at height 1, so the next pass stores a run
    # that stops one header short of the finalized segment.
    assert {:ok, _source} = admit(@late, 1)
    assert {:ok, _backfill} = pass()
    assert Enum.map(canonical_heights(), & &1) == Enum.to_list(1..8) ++ [10, 11, 12]

    # The provider now serves another fork from height 5 up. The divergence is
    # found at the cursor, and the ancestor beneath it is height 4.
    Endpoint.script(chain(blocks(1..20, fork(5..20, "b")), safe: 12, finalized: 12))

    assert {:ok, _rewind} = pass()
    assert cursor().next_block_to_fetch == 5

    # Exactly the run above the ancestor goes. Heights 10 to 12 sit above the
    # gap at 9: they are no part of this reorg, they are still canonical, and
    # their finality was never a reason to refuse it.
    assert orphaned() == [5, 6, 7, 8]
    assert canonical_heights() == [1, 2, 3, 4, 10, 11, 12]
    assert finalized() == [10, 11, 12]
  end

  test "a local run longer than the bound refuses the whole rewind and writes nothing" do
    start_endpoint(chain(blocks(1..40), safe: 25, finalized: 4))
    assert {:ok, _source} = admit(@auction, 10)

    assert {:ok, _first} = pass()
    assert {:ok, _second} = pass()
    assert canonical_heights() == Enum.to_list(10..25)
    assert finalized() == []

    # A late address pulls the cursor below a stored run longer than the bound,
    # and the provider has forked underneath all of it. The divergence is at 10,
    # so the ancestor is 9 and the run above it is every height the ledger holds.
    assert {:ok, _source} = admit(@late, 5)
    assert cursor().next_block_to_fetch == 5
    Endpoint.script(chain(blocks(1..40, fork(10..40, "b")), safe: 25, finalized: 4))

    ancestor = 9
    assert pass() == {:error, {:rewind_over_bound, ancestor + Handler.bound() + 1}}

    # Nothing was demoted, nothing was stored, and the cursor still names the
    # backfill the new address was admitted for.
    assert orphaned() == []
    assert canonical_heights() == Enum.to_list(10..25)
    assert cursor().next_block_to_fetch == 5
  end

  defp canonical_heights,
    do: stored_blocks() |> Enum.filter(& &1.canonical) |> Enum.map(& &1.block_number)
end
