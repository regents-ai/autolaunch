defmodule Autolaunch.Indexer.CursorLockTest do
  @moduledoc """
  What the shared cursor row lock guarantees, proven on real second connections.

  PostgreSQL reports the ordering through `pg_blocking_pids`, so nothing here
  waits on a clock: a source admission and a range commit contend for one lock,
  and a lease admits exactly one writer while still letting the next pass start
  as soon as the last one lets go.

  Protects SOURCE_SET_CHANGE_INVALIDATES_STALE_WORK in both orderings. A range
  planned before an address was watched must never commit over the heights that
  address emits from, so a genuinely new source clears the lease whatever its
  start block; and when the commit reaches the lock first, the admission behind
  it pulls the cursor back exactly as far as the new address needs and no
  further. Re-stating a source the ledger already watches is the same fact twice
  and is allowed to disturb nothing at all.
  """

  use Autolaunch.IndexerCase, async: false

  alias Autolaunch.Indexer.{Handler, Ledger}

  @auction "0x00000000000000000000000000000000000000aa"
  @late "0x00000000000000000000000000000000000000bb"

  setup do
    start_endpoint(chain(blocks(10..14), safe: 12, finalized: 10))
    {:ok, _source} = admit(@auction, 10)
    :ok
  end

  test "an admission that rewinds the cursor orders ahead of a range planned from the old one" do
    {:ok, lease} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)
    assert lease.next_block == 10

    admission = holding(fn -> Handler.admit_source(@late, 5) end)
    commit = contending(fn -> Ledger.commit(lease, planned_range(), Handler.bound()) end)

    assert_blocked_by(commit, admission)
    assert {:ok, _source} = release(admission)

    # The commit takes the lock second, sees a cursor that is no longer the one
    # its range was planned from, and rolls the whole range back.
    assert settled(commit) == {:error, :lease_lost}
    assert cursor().next_block_to_fetch == 5
    assert stored_blocks() == []
  end

  test "one lease admits one writer, and the next pass starts as soon as it is released" do
    granting = holding(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)
    rival = contending(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)

    assert_blocked_by(rival, granting)
    assert {:ok, lease} = release(granting)

    assert settled(rival) == {:error, :leased}

    # Forward progress needs no expiry: releasing the lease admits the next pass.
    assert {:ok, _released} = unboxed(fn -> Ledger.release(lease) end)
    assert {:ok, next} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)
    assert next.next_block == 10
    assert next.owner != lease.owner
  end

  test "a commit under a lease another writer replaced advances nothing" do
    {:ok, stale} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)
    assert {:ok, _released} = unboxed(fn -> Ledger.release(stale) end)
    assert {:ok, _live} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)

    assert unboxed(fn -> Ledger.commit(stale, planned_range(), Handler.bound()) end) ==
             {:error, :lease_lost}

    assert cursor().next_block_to_fetch == 10
    assert stored_blocks() == []
  end

  test "a source admitted at the cursor invalidates the lease its range was planned under" do
    {:ok, lease} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)
    assert lease.next_block == 10

    admission = holding(fn -> Handler.admit_source(@late, 10) end)
    commit = contending(fn -> Ledger.commit(lease, planned_range(), Handler.bound()) end)

    assert_blocked_by(commit, admission)
    assert {:ok, _source} = release(admission)

    # Nothing about the cursor's position refuses this commit: the range starts
    # exactly where the cursor already stood. Only the cleared lease does, and
    # it must, because that range was planned without this address in the set
    # and would have committed straight over the logs it emits.
    assert cursor().next_block_to_fetch == 10
    assert settled(commit) == {:error, :lease_lost}
    assert stored_blocks() == []
  end

  test "a source admitted above the in-flight range invalidates its lease all the same" do
    {:ok, lease} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)

    assert {:ok, _source} = unboxed(fn -> Handler.admit_source(@late, 40) end)

    # Deliberately unconditional: the admission delay is human-scale, and no
    # rule about whose range overlaps whose start block is worth a race.
    assert cursor().next_block_to_fetch == 10

    assert unboxed(fn -> Ledger.commit(lease, planned_range(), Handler.bound()) end) ==
             {:error, :lease_lost}

    assert stored_blocks() == []
  end

  test "re-stating an admitted source disturbs neither the cursor nor a live lease" do
    {:ok, lease} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)

    assert {:ok, _replayed} = unboxed(fn -> Handler.admit_source(@auction, 10) end)

    assert cursor().next_block_to_fetch == 10
    assert length(sources()) == 1

    assert {:ok, _committed} =
             unboxed(fn -> Ledger.commit(lease, planned_range(), Handler.bound()) end)

    assert Enum.map(stored_blocks(), & &1.block_number) == [10, 11, 12]
    assert cursor().next_block_to_fetch == 13
  end

  test "a commit that reaches the lock first stands, and the admission rewinds only to its start" do
    {:ok, lease} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)

    commit = holding(fn -> Ledger.commit(lease, planned_range(), Handler.bound()) end)
    admission = contending(fn -> Handler.admit_source(@late, 11) end)

    assert_blocked_by(admission, commit)
    assert {:ok, _committed} = release(commit)
    assert {:ok, _source} = settled(admission)

    # The range that won stays committed, and the cursor comes back to the new
    # address's own start rather than to the foot of the range that just landed.
    assert Enum.map(stored_blocks(), & &1.block_number) == [10, 11, 12]
    assert cursor().next_block_to_fetch == 11
  end

  defp planned_range do
    headers =
      Enum.map(10..12, fn number ->
        %{number: number, hash: block_hash(number), parent_hash: block_hash(number - 1)}
      end)

    {:range, headers, [], %{number: 10, hash: block_hash(10)}}
  end
end
