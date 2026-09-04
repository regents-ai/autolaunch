defmodule Autolaunch.Indexer.ProvenanceTest do
  @moduledoc """
  Where a stored log is allowed to have come from, and what admits its address.

  The address filter is a request, not a guarantee, so every log the provider
  returns is checked against the admitted set, against the height the fetched
  headers place it at, and against the block its address became interesting at.
  The heads the range is drawn between are checked against each other the same
  way, and admitting a source states one fact that cannot be quietly restated
  as another.
  """

  use Autolaunch.IndexerCase, async: false

  @auction "0x00000000000000000000000000000000000000aa"
  @late "0x00000000000000000000000000000000000000bb"
  @stranger "0x00000000000000000000000000000000000000cc"

  test "a log placed outside the fetched range advances nothing" do
    start_endpoint(chain(stray(), safe: 12, finalized: 9))
    assert {:ok, _source} = admit(@auction, 10)

    assert pass() == {:error, :log_outside_range}
    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 10
  end

  test "a log from an address that was never admitted advances nothing" do
    emitted = emit(watched(), 11, [%{index: 0, address: @stranger}])
    start_endpoint(chain(emitted, safe: 12, finalized: 9, filter_addresses: false))
    assert {:ok, _source} = admit(@auction, 10)

    assert pass() == {:error, :unadmitted_emitter}
    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 10
  end

  test "a log emitted before its address became interesting advances nothing" do
    emitted = emit(watched(), 7, [%{index: 0, address: @auction}])
    start_endpoint(chain(emitted, safe: 12, finalized: 9))
    assert {:ok, _early} = admit(@late, 5)
    assert {:ok, _source} = admit(@auction, 10)

    assert pass() == {:error, :log_before_start}
    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 5
  end

  test "a log the provider has retracted advances nothing" do
    emitted = emit(watched(), 11, [%{index: 0, address: @auction, removed: true}])
    start_endpoint(chain(emitted, safe: 12, finalized: 9))
    assert {:ok, _source} = admit(@auction, 10)

    assert pass() == {:error, :removed_log}
    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 10
  end

  test "a finalized head above the safe head advances nothing" do
    start_endpoint(chain(watched(), safe: 12, finalized: 14))
    assert {:ok, _source} = admit(@auction, 10)

    assert pass() == {:error, :head_disorder}
    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 10
  end

  test "a range reaching a safe head its own headers do not carry advances nothing" do
    start_endpoint(chain(watched(), safe: 12, finalized: 9, safe_hash: block_hash(12, "b")))

    assert {:ok, _source} = admit(@auction, 10)

    assert pass() == {:error, :safe_head_mismatch}
    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 10
  end

  test "re-admitting the same address at the same start returns it and moves nothing" do
    start_endpoint(chain(watched(), safe: 12, finalized: 9))
    assert {:ok, admitted} = admit(@auction, 10)
    assert {:ok, _range} = pass()
    assert cursor().next_block_to_fetch == 13

    assert {:ok, replayed} = admit(@auction, 10)

    assert replayed.id == admitted.id
    assert cursor().next_block_to_fetch == 13
    assert length(sources()) == 1
  end

  test "the same address at a different start fails closed and moves nothing" do
    start_endpoint(chain(watched(), safe: 12, finalized: 9))
    assert {:ok, _source} = admit(@auction, 10)
    assert {:ok, _range} = pass()

    assert admit(@auction, 6) == {:error, :source_start_conflict}

    assert cursor().next_block_to_fetch == 13
    assert Enum.map(sources(), & &1.start_block) == [10]
  end

  defp watched, do: 5..14 |> blocks() |> emit(11, [%{index: 0, address: @auction}])

  defp stray do
    Enum.map(watched(), fn
      %{number: 11} = block ->
        %{block | logs: Enum.map(block.logs, &%{&1 | "blockHash" => block_hash(99)})}

      block ->
        block
    end)
  end
end
