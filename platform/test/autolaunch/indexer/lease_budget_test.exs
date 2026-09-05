defmodule Autolaunch.Indexer.LeaseBudgetTest do
  @moduledoc """
  That one granted lease outlives the pass it was granted for.

  Nothing renews a lease mid-pass, so the only thing that keeps a slow provider
  from making every commit uncommittable is arithmetic: the bound caps how many
  requests a pass can issue, the transport caps how long one request can take,
  and the lease is derived from their product rather than picked. The counts are
  proven by the requests the fake endpoint was actually handed, so no test waits
  on a clock.
  """

  use Autolaunch.IndexerCase, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.Indexer.{Handler, Ledger, Rpc}
  alias Autolaunch.TestAutolaunchIndexerChainClient, as: Endpoint

  @auction "0x00000000000000000000000000000000000000aa"

  test "the lease outlives every request the bound permits plus the commit after it" do
    assert Handler.bound() == 8
    assert Handler.max_requests() == Handler.bound() + 4
    assert Handler.lease_ms() > Handler.max_requests() * Rpc.max_request_ms()
  end

  test "a full-bound ingest pass spends exactly the budget the lease was derived from" do
    start_endpoint(chain(deep(), safe: 40, finalized: 9))
    assert {:ok, _source} = admit(@auction, 10)
    Endpoint.forget()

    assert {:ok, _range} = pass()

    assert Enum.map(stored_blocks(), & &1.block_number) == Enum.to_list(10..17)
    assert length(Endpoint.requests()) == Handler.max_requests()
  end

  test "a reorg pass stays inside the same budget and asks for one range header first" do
    start_endpoint(chain(deep(), safe: 17, finalized: 9))
    assert {:ok, _source} = admit(@auction, 10)
    assert {:ok, _range} = pass()

    Endpoint.script(chain(deep(fork(12..40, "b")), safe: 40, finalized: 9))
    Endpoint.forget()

    assert {:ok, _rewind} = pass()
    assert cursor().next_block_to_fetch == 12
    assert length(Endpoint.requests()) <= Handler.max_requests()

    # The divergence is found on the range's first header, so the rest of the
    # range and its logs are never asked for.
    assert heights() == [18, 17, 16, 15, 14, 13, 12, 11]
    assert Endpoint.requests("eth_getLogs") == []
  end

  test "a failing header ends the range instead of spending the rest of the budget" do
    start_endpoint(chain(deep(), safe: 40, finalized: 9, fault: {:unavailable, 12}))
    assert {:ok, _source} = admit(@auction, 10)
    Endpoint.forget()

    assert pass() == {:error, :chain_unavailable}

    assert heights() == [10, 11, 12]
    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 10
  end

  test "another instance holding the chain is a quiet idle pass, not a diagnostic" do
    start_endpoint(chain(deep(), safe: 40, finalized: 9))
    assert {:ok, _source} = admit(@auction, 10)
    assert {:ok, held} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)

    diagnostic = capture_log(fn -> assert pass() == {:error, :leased} end)

    refute diagnostic =~ "autolaunch indexer"
    assert stored_blocks() == []
    assert {:ok, _released} = unboxed(fn -> Ledger.release(held) end)
  end

  defp deep(forks \\ %{}), do: blocks(5..40, forks)

  # The exact heights the pass asked for, in the order it asked for them.
  defp heights do
    "eth_getBlockByNumber"
    |> Endpoint.requests()
    |> Enum.map(fn %{params: [block, false]} -> block end)
    |> Enum.reject(&(&1 in ["safe", "finalized"]))
    |> Enum.map(&String.to_integer(String.trim_leading(&1, "0x"), 16))
  end
end
