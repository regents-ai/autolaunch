defmodule Autolaunch.Chain.RpcLogsTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Chain.Rpc

  # LOGS_SPLIT_ONLY_ON_REFUSAL: Base makes five blocks a second from
  # 5 November 2026, so a history read from a pool's opening block to the head
  # spans ten times more blocks than before. A span the node refuses is read as
  # its halves until every log is in, in chain order; a node that does not
  # answer fails the read with its first request.

  defmodule Node do
    # Refuses any span over 100 blocks and holds one log every 50 blocks.
    def post(_url, options) do
      [%{fromBlock: from, toBlock: to}] = options[:json].params
      {from, to} = {number(from), number(to)}
      Process.put(:requests, [{from, to} | Process.get(:requests, [])])

      if to - from + 1 > 100,
        do: {:ok, %{status: 200, body: %{"error" => %{"message" => "range too large"}}}},
        else: {:ok, %{status: 200, body: %{"result" => logs(from, to)}}}
    end

    defp logs(from, to), do: for(n <- from..to, rem(n, 50) == 0, do: %{"block" => n})
    defp number("0x" <> hex), do: String.to_integer(hex, 16)
  end

  defmodule Down do
    def post(_url, _options) do
      Process.put(:requests, [:sent | Process.get(:requests, [])])
      {:error, %Req.TransportError{reason: :timeout}}
    end
  end

  defmodule Busy do
    # Finch raises this, rather than returning an error, when every pooled
    # connection stays busy past the pool wait.
    def post(_url, _options),
      do: raise("Finch was unable to provide a connection within the timeout")
  end

  setup do
    Application.put_env(:autolaunch, :rpc_logs_node, Node)
    Application.put_env(:autolaunch, :rpc_logs_down, Down)
    Application.put_env(:autolaunch, :rpc_logs_busy, Busy)
    :ok
  end

  test "a refused span is read as its halves, every log once and in order" do
    opts = [client_key: :rpc_logs_node, rpc_url: "https://node.invalid"]

    assert {:ok, logs} = Rpc.logs("0x" <> String.duplicate("1", 40), [], 0, 999, opts)
    assert Enum.map(logs, & &1["block"]) == Enum.to_list(0..950//50)
    assert Enum.all?(Process.get(:requests), fn {from, to} -> to >= from end)
  end

  test "a node that does not answer fails the read with one request" do
    opts = [client_key: :rpc_logs_down, rpc_url: "https://node.invalid"]

    assert {:error, :chain_unavailable} =
             Rpc.logs("0x" <> String.duplicate("1", 40), [], 0, 999, opts)

    assert Process.get(:requests) == [:sent]
  end

  test "a connection pool that stays busy fails the read as unavailable" do
    opts = [client_key: :rpc_logs_busy, rpc_url: "https://node.invalid"]

    assert {:error, :chain_unavailable} =
             Rpc.logs("0x" <> String.duplicate("1", 40), [], 0, 999, opts)
  end
end
