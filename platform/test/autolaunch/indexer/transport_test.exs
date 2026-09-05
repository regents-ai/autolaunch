defmodule Autolaunch.Indexer.TransportTest do
  @moduledoc """
  What one JSON-RPC exchange is allowed to cost, and where it is allowed to go.

  Protects TRUE_TOTAL_RPC_DEADLINE. A blocked transport proves the deadline is
  the application's own and enforced rather than a transport stage's estimate:
  the exchange is abandoned, the work behind it is killed, the failure is
  reported without the key-bearing endpoint, and the chain is handed back inside
  the lease that was derived from that same ceiling. A real local HTTP answer on
  a real socket proves the two things no scripted transport can: that a redirect
  is refused instead of followed, and that a server error is still answered
  exactly once.
  """

  use Autolaunch.IndexerCase, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.Indexer.{Handler, Ledger}

  @auction "0x00000000000000000000000000000000000000aa"
  @endpoint "https://base-mainnet.example.invalid/v2/8f3c1d9e-provider-key"
  @watch :autolaunch_indexer_blocked_transport

  @moved "HTTP/1.1 302 Found\r\nlocation: /elsewhere\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  @unavailable "HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"

  defmodule BlockedTransport do
    @moduledoc "Takes the exchange, announces the process carrying it, and never answers."

    @spec post(String.t(), keyword()) :: no_return()
    def post(_url, _options) do
      send(:autolaunch_indexer_blocked_transport, {:blocked, self()})
      Process.sleep(:infinity)
    end
  end

  test "a blocked exchange is abandoned at the owned deadline and its work is killed" do
    watch_transport()

    configure(
      autolaunch_indexer_http_client: BlockedTransport,
      autolaunch_indexer_rpc_url: @endpoint,
      autolaunch_indexer_deadline_ms: 100
    )

    assert {:ok, _source} = admit(@auction, 10)

    diagnostic = capture_log(fn -> assert pass() == {:error, :chain_unavailable} end)

    # No stage timeout ended this: the transport never answered, so only the
    # deadline could have, and the process holding it is gone rather than left
    # to answer into a later pass.
    assert_receive {:terminated, :killed}, 5_000

    assert diagnostic =~ "class: :timeout"
    refute diagnostic =~ @endpoint
    refute diagnostic =~ "provider-key"

    assert stored_blocks() == []
    assert cursor().next_block_to_fetch == 10

    # The lease outlived the exchange it was derived from, so the chain is free
    # again for the next pass rather than held until an expiry.
    assert {:ok, lease} = unboxed(fn -> Ledger.acquire(chain_id(), Handler.lease_ms()) end)
    assert {:ok, _released} = unboxed(fn -> Ledger.release(lease) end)
  end

  test "a real redirect answer is refused rather than followed" do
    configure(autolaunch_indexer_http_client: Req, autolaunch_indexer_rpc_url: serving(@moved))
    assert {:ok, _source} = admit(@auction, 10)

    diagnostic = capture_log(fn -> assert pass() == {:error, :chain_unavailable} end)

    # The pass has already returned, so anything the redirect sent the client
    # after is already in this mailbox. There is nothing.
    assert_receive {:served, _exchange}, 5_000
    refute_received {:served, _followed}

    assert diagnostic =~ "class: :http"
    assert stored_blocks() == []
  end

  test "a real server error is still answered exactly once, never retried" do
    configure(
      autolaunch_indexer_http_client: Req,
      autolaunch_indexer_rpc_url: serving(@unavailable)
    )

    assert {:ok, _source} = admit(@auction, 10)

    diagnostic = capture_log(fn -> assert pass() == {:error, :chain_unavailable} end)

    assert_receive {:served, _exchange}, 5_000
    refute_received {:served, _retried}

    assert diagnostic =~ "class: :http"
    assert stored_blocks() == []
  end

  ## A real socket answering real HTTP

  defp serving(answer) do
    test = self()
    start_supervised!({Task, fn -> listen(answer, test) end})
    assert_receive {:listening, port}, 5_000
    "http://127.0.0.1:#{port}/"
  end

  defp listen(answer, test) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    send(test, {:listening, port})
    serve(listener, answer, test)
  end

  # The answered socket is deliberately left open: closing it while the client
  # is still writing would reach the indexer as a transport failure rather than
  # as the status this test is about. Both sockets die with this process.
  defp serve(listener, answer, test) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {:ok, exchange} = :gen_tcp.recv(socket, 0)
    send(test, {:served, exchange})
    :gen_tcp.send(socket, answer)
    serve(listener, answer, test)
  end

  ## Watching the process the exchange runs in

  defp watch_transport do
    test = self()
    Process.register(start_supervised!({Task, fn -> await_death(test) end}), @watch)
  end

  defp await_death(test) do
    receive do
      {:blocked, worker} ->
        ref = Process.monitor(worker)

        receive do
          {:DOWN, ^ref, :process, ^worker, reason} -> send(test, {:terminated, reason})
        end
    end
  end

  defp configure(settings) do
    Enum.each(settings, fn {key, value} ->
      previous = Application.fetch_env(:autolaunch, key)
      Application.put_env(:autolaunch, key, value)
      on_exit(fn -> restore(key, previous) end)
    end)
  end

  defp restore(key, {:ok, previous}), do: Application.put_env(:autolaunch, key, previous)
  defp restore(key, :error), do: Application.delete_env(:autolaunch, key)
end
