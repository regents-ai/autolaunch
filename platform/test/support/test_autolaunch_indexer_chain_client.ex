defmodule Autolaunch.TestAutolaunchIndexerChainClient do
  @moduledoc """
  A fake Base JSON-RPC endpoint for the Autolaunch log ledger.

  It answers from a scripted chain and keeps every request body it was handed,
  so a test can quote the exact call the indexer made rather than trust that it
  made one. Faults are scripted the same way, which is how a transport failure
  is proven to redact its endpoint without any provider being contacted, and how
  a provider that misbehaves — a bad status, an RPC error body, a foreign
  response id, an address filter it ignores — is put in front of the indexer.
  """

  use Agent

  @spec start_link(map()) :: Agent.on_start()
  def start_link(chain),
    do: Agent.start_link(fn -> %{chain: chain, requests: [], watcher: nil} end, name: __MODULE__)

  @doc "Announces every request to the caller, so a test waits on a call rather than a clock."
  @spec watch() :: :ok
  def watch do
    watcher = self()
    Agent.update(__MODULE__, &%{&1 | watcher: watcher})
  end

  @doc "Replaces the chain the endpoint answers from."
  @spec script(map()) :: :ok
  def script(chain), do: Agent.update(__MODULE__, &%{&1 | chain: chain})

  @doc "Forgets every request recorded so far."
  @spec forget() :: :ok
  def forget, do: Agent.update(__MODULE__, &%{&1 | requests: []})

  @doc "Every request body received so far, oldest first."
  @spec requests() :: [map()]
  def requests, do: __MODULE__ |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "Every request body for one JSON-RPC method, oldest first."
  @spec requests(String.t()) :: [map()]
  def requests(method), do: Enum.filter(requests(), &(&1.method == method))

  @spec post(String.t(), keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def post(_url, options) do
    request = Keyword.fetch!(options, :json)

    __MODULE__
    |> Agent.get_and_update(&{{&1.chain, &1.watcher}, %{&1 | requests: [request | &1.requests]}})
    |> announced(request)
    |> respond(request)
  end

  defp announced({chain, nil}, _request), do: chain

  defp announced({chain, watcher}, request) do
    send(watcher, {:rpc, request.method})
    chain
  end

  defp respond(chain, request) do
    case fault(chain.fault, request) do
      :none -> envelope(1, %{"result" => answer(chain, request)})
      response -> response
    end
  end

  defp fault({:raise, message}, _request), do: raise(message)
  defp fault({:status, status}, _request), do: {:ok, %{status: status, body: %{}}}
  defp fault(:rpc_error, _request), do: envelope(1, %{"error" => %{"code" => -32_000}})
  defp fault(:foreign_id, _request), do: envelope(99, %{"result" => nil})

  defp fault({:unavailable, height}, %{method: "eth_getBlockByNumber", params: [block, false]}),
    do: unavailable(block == hex(height))

  defp fault(_none, _request), do: :none

  defp unavailable(true), do: {:ok, %{status: 503, body: %{}}}
  defp unavailable(false), do: :none

  defp answer(chain, %{method: "eth_chainId"}), do: chain.chain_id

  defp answer(chain, %{method: "eth_getBlockByNumber", params: ["safe", false]}),
    do: tagged(header(chain, chain.safe), chain.safe_hash)

  defp answer(chain, %{method: "eth_getBlockByNumber", params: ["finalized", false]}),
    do: header(chain, chain.finalized)

  defp answer(chain, %{method: "eth_getBlockByNumber", params: ["0x" <> height, false]}),
    do: header(chain, String.to_integer(height, 16))

  defp answer(chain, %{
         method: "eth_getLogs",
         params: [%{"fromBlock" => from, "toBlock" => to, "address" => addresses}]
       }) do
    chain.blocks
    |> Enum.filter(&(&1.number in quantity(from)..quantity(to)//1))
    |> Enum.flat_map(& &1.logs)
    |> Enum.filter(&emitted?(chain.filter_addresses, &1, addresses))
  end

  defp emitted?(false, _log, _addresses), do: true
  defp emitted?(true, log, addresses), do: log["address"] in addresses

  defp header(chain, number) do
    case Enum.find(chain.blocks, &(&1.number == number)) do
      nil ->
        nil

      block ->
        %{"number" => hex(block.number), "hash" => block.hash, "parentHash" => block.parent}
    end
  end

  # A safe tag that names a hash the range's own headers do not carry is how a
  # provider answering from two chains at once is put in front of the indexer.
  defp tagged(header, nil), do: header
  defp tagged(header, hash), do: %{header | "hash" => hash}

  defp envelope(id, body),
    do: {:ok, %{status: 200, body: Map.merge(%{"jsonrpc" => "2.0", "id" => id}, body)}}

  defp hex(number), do: "0x" <> String.downcase(Integer.to_string(number, 16))
  defp quantity("0x" <> digits), do: String.to_integer(digits, 16)
end
