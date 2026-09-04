defmodule Autolaunch.Indexer.OperatingPathTest do
  @moduledoc """
  The path this ticket exists to produce, end to end against a fake Base
  endpoint: a private source admission opens the chain cursor, one bounded pass
  commits the safe range exactly, and the next pass resumes from the stored
  position instead of re-reading what is already evidence.
  """

  use Autolaunch.IndexerCase, async: false

  alias Autolaunch.TestAutolaunchIndexerChainClient, as: Endpoint

  @auction "0x00000000000000000000000000000000000000aa"

  test "admission opens the cursor, a safe range commits, and the next pass resumes" do
    blocks =
      10..14
      |> blocks()
      |> emit(11, [%{index: 0, address: @auction}])
      |> emit(13, [%{index: 0, address: @auction}, %{index: 1, address: @auction}])

    start_endpoint(chain(blocks, safe: 12, finalized: 10))

    assert {:ok, source} = admit(@auction, 10)
    assert source.address == @auction
    assert cursor().next_block_to_fetch == 10

    assert {:ok, _range} = pass()

    assert Enum.map(stored_blocks(), & &1.block_number) == [10, 11, 12]
    assert Enum.map(stored_logs(), &{&1.block_hash, &1.log_index}) == [{block_hash(11), 0}]
    assert cursor().next_block_to_fetch == 13

    # Finality is the exact provider hash at that height, never a depth guess.
    assert Enum.filter(stored_blocks(), & &1.finalized) |> Enum.map(& &1.block_number) == [10]

    Endpoint.script(chain(blocks, safe: 14, finalized: 12))
    assert {:ok, _range} = pass()

    assert Enum.map(stored_blocks(), & &1.block_number) == [10, 11, 12, 13, 14]
    assert Enum.map(stored_logs(), & &1.log_index) == [0, 0, 1]
    assert cursor().next_block_to_fetch == 15

    assert Enum.filter(stored_blocks(), & &1.finalized) |> Enum.map(& &1.block_number) == [
             10,
             11,
             12
           ]

    # One header row per block and nothing else per block; logs are the only
    # other rows the ledger holds.
    assert length(stored_blocks()) == 5
    assert length(stored_logs()) == 3

    # The resume reads forward from the stored cursor, never from the start.
    assert Endpoint.requests("eth_getLogs") == [
             %{
               jsonrpc: "2.0",
               id: 1,
               method: "eth_getLogs",
               params: [%{"fromBlock" => "0xa", "toBlock" => "0xc", "address" => [@auction]}]
             },
             %{
               jsonrpc: "2.0",
               id: 1,
               method: "eth_getLogs",
               params: [%{"fromBlock" => "0xd", "toBlock" => "0xe", "address" => [@auction]}]
             }
           ]

    # The ingest edge is always the provider's safe head; latest is never read.
    assert %{jsonrpc: "2.0", id: 1, method: "eth_getBlockByNumber", params: ["safe", false]} in Endpoint.requests()

    assert %{jsonrpc: "2.0", id: 1, method: "eth_getBlockByNumber", params: ["finalized", false]} in Endpoint.requests()

    refute Enum.any?(Endpoint.requests(), &("latest" in &1.params))
  end
end
