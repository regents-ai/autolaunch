defmodule Autolaunch.Indexer.IngestTest do
  @moduledoc """
  What one bounded pass will and will not accept from the provider.

  A first range bootstraps where nothing is stored to link to, a source admitted
  behind the cursor backfills the addresses it opened, and missing, broken,
  stray or wrong-chain evidence advances nothing at all. A range that overlaps
  stored headers is compared height by height, a divergence rewinds only what is
  still revisable, and a provider failure during the backward walk is a failure
  rather than evidence of a fork.
  """

  use Autolaunch.IndexerCase, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.TestAutolaunchIndexerChainClient, as: Endpoint

  @auction "0x00000000000000000000000000000000000000aa"
  @late "0x00000000000000000000000000000000000000bb"

  test "a source admitted behind the cursor rewinds, backfills its address and replays the rest" do
    start_endpoint(chain(watched(), safe: 12, finalized: 10))
    assert {:ok, _source} = admit(@auction, 10)

    # Bootstrap: with nothing stored beneath the range, there is no predecessor
    # to link to and the provider's own parent chain is the only evidence.
    assert {:ok, _range} = pass()
    assert Enum.map(stored_blocks(), & &1.block_number) == [10, 11, 12]
    assert Enum.map(stored_logs(), & &1.address) == [@auction]

    assert {:ok, _source} = admit(@late, 5)
    assert cursor().next_block_to_fetch == 5

    assert {:ok, _range} = pass()
    assert Enum.map(stored_blocks(), & &1.block_number) == Enum.to_list(5..12)
    assert Enum.map(stored_logs(), & &1.address) == [@late, @auction]
    assert cursor().next_block_to_fetch == 13
  end

  test "finality promotes on a pass where the safe head has not moved" do
    start_endpoint(chain(watched(), safe: 12, finalized: 10))
    assert {:ok, _source} = admit(@auction, 10)
    assert {:ok, _range} = pass()
    assert finalized() == [10]

    Endpoint.script(chain(watched(), safe: 12, finalized: 12))
    assert {:ok, _promotion} = pass()

    assert finalized() == [10, 11, 12]
    assert cursor().next_block_to_fetch == 13
  end

  test "a missing header advances nothing" do
    start_endpoint(chain(without(11), safe: 12, finalized: 10))
    assert {:ok, _source} = admit(@auction, 10)

    assert pass() == {:error, :malformed}
    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 10
  end

  test "a broken parent link inside the range advances nothing" do
    start_endpoint(chain(unlinked(), safe: 12, finalized: 10))
    assert {:ok, _source} = admit(@auction, 10)

    assert pass() == {:error, :gapped_range}
    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 10
  end

  test "a provider that is not Base mainnet advances nothing" do
    start_endpoint(chain(watched(), safe: 12, finalized: 10, chain_id: "0x1"))
    assert {:ok, _source} = admit(@auction, 10)

    assert pass() == {:error, :wrong_chain}
    assert stored_blocks() == []
  end

  test "a divergence below the earliest admitted source start mutates nothing and reports once" do
    start_endpoint(chain(watched(), safe: 12, finalized: 10))
    assert {:ok, _source} = admit(@auction, 10)
    assert {:ok, _range} = pass()

    before_blocks = stored_blocks()
    Endpoint.script(chain(blocks(10..13, fork(10..13, "b")), safe: 13, finalized: 10))

    diagnostic = capture_log(fn -> assert pass() == {:error, :no_common_ancestor} end)

    assert length(String.split(diagnostic, "autolaunch indexer")) == 2
    assert diagnostic =~ "no_common_ancestor"

    assert Enum.map(stored_blocks(), &{&1.block_hash, &1.canonical}) ==
             Enum.map(before_blocks, &{&1.block_hash, &1.canonical})

    assert cursor().next_block_to_fetch == 13
  end

  test "an overlapping late rewind orphans the old suffix, keeps its position and stores the fork" do
    start_endpoint(chain(deep(), safe: 12, finalized: 9))
    assert {:ok, _source} = admit(@auction, 10)
    assert {:ok, _range} = pass()
    assert Enum.map(stored_blocks(), & &1.block_number) == [10, 11, 12]

    # The new source pulls the cursor below the ledger, so the pass that follows
    # covers heights the ledger already holds on the fork it is abandoning.
    assert {:ok, _source} = admit(@late, 5)
    assert cursor().next_block_to_fetch == 5
    Endpoint.script(chain(deep(fork(10..20, "b")), safe: 12, finalized: 9))

    assert {:ok, _forked} = pass()
    assert orphaned() == [10, 11, 12]

    # The cursor stays where the new source put it: the divergence is not a
    # reason to skip the blocks that source was admitted for.
    assert cursor().next_block_to_fetch == 5

    assert {:ok, _range} = pass()
    assert cursor().next_block_to_fetch == 13
    assert Enum.map(canonical_blocks(), & &1.block_number) == Enum.to_list(5..12)
    assert canonical?(block_hash(10, "b"))
    refute canonical?(block_hash(10))

    # The new source's own backfilled log and the re-included auction log are
    # both canonical, and the auction log's former placement stays as evidence.
    assert canonical_logs() ==
             Enum.sort([{block_hash(7), @late}, {block_hash(11, "b"), @auction}])

    assert Enum.any?(stored_logs(), &(&1.block_hash == block_hash(11)))
  end

  test "a rewind that would cross the highest finalized block refuses and mutates nothing" do
    start_endpoint(chain(deep(), safe: 12, finalized: 12))
    assert {:ok, _source} = admit(@auction, 10)
    assert {:ok, _range} = pass()
    assert finalized() == [10, 11, 12]

    Endpoint.script(chain(deep(fork(12..20, "b")), safe: 13, finalized: 12))

    assert pass() == {:error, {:finalized_rewind, 12}}
    assert orphaned() == []
    assert finalized() == [10, 11, 12]
    assert cursor().next_block_to_fetch == 13
  end

  test "a provider failure during the backward walk aborts it and orphans nothing" do
    start_endpoint(chain(deep(), safe: 17, finalized: 9))
    assert {:ok, _source} = admit(@auction, 10)
    assert {:ok, _range} = pass()
    assert cursor().next_block_to_fetch == 18

    before_blocks = stored_blocks()

    Endpoint.script(
      chain(deep(fork(12..20, "b")), safe: 20, finalized: 9, fault: {:unavailable, 14})
    )

    assert pass() == {:error, :chain_unavailable}

    # The walk reached the failing height and stopped there: an unanswered
    # request is not a different hash, so nothing diverged and nothing moved.
    assert Enum.map(stored_blocks(), &{&1.block_hash, &1.canonical}) ==
             Enum.map(before_blocks, &{&1.block_hash, &1.canonical})

    assert cursor().next_block_to_fetch == 18
  end

  test "no admitted source is a quiet idle pass, not a diagnostic" do
    start_endpoint(chain(deep(), safe: 12, finalized: 9))

    diagnostic = capture_log(fn -> assert pass() == {:error, :no_source_admitted} end)

    refute diagnostic =~ "autolaunch indexer"
    assert stored_blocks() == []
  end

  defp watched do
    5..14
    |> blocks()
    |> emit(7, [%{index: 0, address: @late}])
    |> emit(11, [%{index: 0, address: @auction}])
  end

  defp deep(forks \\ %{}) do
    5..20
    |> blocks(forks)
    |> emit(7, [%{index: 0, address: @late}])
    |> emit(11, [%{index: 0, address: @auction}])
  end

  defp without(number), do: Enum.reject(watched(), &(&1.number == number))

  defp unlinked do
    Enum.map(watched(), fn
      %{number: 12} = block -> %{block | parent: block_hash(9)}
      block -> block
    end)
  end

  defp canonical_blocks, do: Enum.filter(stored_blocks(), & &1.canonical)

  defp canonical_logs do
    stored_logs()
    |> Enum.filter(&canonical?(&1.block_hash))
    |> Enum.map(&{&1.block_hash, &1.address})
    |> Enum.sort()
  end
end
