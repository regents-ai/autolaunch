defmodule Autolaunch.BaseRpcStub do
  @moduledoc """
  One JSON-RPC transport double for the Base reads a chain test makes.

  Chain identity, the `safe` header, headers by number, receipts and transactions
  have exactly one shape for every surface. Only the block-pinned `eth_call`
  answers differ, so a test supplies those as the `:calls` function it installs.
  """

  @safe_hash "0x" <> String.duplicate("5a", 32)
  @receipt_block_hash "0x" <> String.duplicate("7b", 32)

  def safe_hash, do: @safe_hash
  def receipt_block_hash, do: @receipt_block_hash

  def post(_url, options) do
    request = options[:json]
    state = state()
    if pid = state[:test_pid], do: send(pid, {:rpc, request.method, request.params})

    case result(request.method, request.params, state) do
      :unavailable -> {:ok, %{status: 200, body: %{"error" => %{"message" => "unavailable"}}}}
      result -> {:ok, %{status: 200, body: %{"result" => result}}}
    end
  end

  defmodule Timeout do
    @moduledoc "Refuses every request, so a transport failure is unavailable and never zero."
    def post(_url, _options), do: {:error, %Req.TransportError{reason: :timeout}}
  end

  defmodule UnsupportedCall do
    @moduledoc "Refuses only `eth_call`, so an unsupported block-pinned read fails closed."

    def post(url, options) do
      if options[:json].method == "eth_call",
        do: {:ok, %{status: 200, body: %{"error" => %{"message" => "unsupported"}}}},
        else: Autolaunch.BaseRpcStub.post(url, options)
    end
  end

  @doc "Points one wallet HTTP client at this stub for the duration of the test."
  def install(client_key, calls) do
    previous_http = Application.get_env(:autolaunch, client_key)
    previous_url = Application.get_env(:autolaunch, :base_read_rpc_url)
    Application.put_env(:autolaunch, client_key, __MODULE__)

    Application.put_env(
      :autolaunch,
      :base_read_rpc_url,
      "https://provider.invalid/super-secret"
    )

    put(%{test_pid: self(), calls: calls})

    ExUnit.Callbacks.on_exit(fn ->
      restore(client_key, previous_http)
      restore(:base_read_rpc_url, previous_url)
      Application.delete_env(:autolaunch, :rpc_stub)
    end)
  end

  def state, do: Application.get_env(:autolaunch, :rpc_stub, %{})

  def put(changes), do: Application.put_env(:autolaunch, :rpc_stub, Map.merge(state(), changes))

  @doc "A receipt with this status, mined into this block and carrying exactly these logs."
  def receipt(hash, block_number, logs, status \\ "0x1"),
    do: %{
      "status" => status,
      "blockNumber" => block_number,
      "blockHash" => @receipt_block_hash,
      "transactionHash" => hash,
      "logs" => logs
    }

  def transaction(hash, envelope),
    do: %{
      "hash" => hash,
      "from" => envelope.expected_signer,
      "to" => envelope.to,
      "input" => envelope.data,
      "value" => "0x0"
    }

  @doc "Every block a pinned `eth_call` was executed against, taken from this test's mailbox."
  def call_blocks(blocks \\ []) do
    receive do
      {:rpc, "eth_call", [_call, block]} -> call_blocks([block | blocks])
      {:rpc, _method, _params} -> call_blocks(blocks)
    after
      0 -> blocks
    end
  end

  def uint(value), do: "0x" <> hex_word(value)

  def hex_word(value),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  def address_word(address),
    do: address |> String.trim_leading("0x") |> String.downcase() |> String.pad_leading(64, "0")

  def address_topic(address), do: "0x" <> address_word(address)

  defp result("eth_chainId", _params, state), do: Map.get(state, :chain_id, "0x2105")

  defp result("eth_getBlockByNumber", ["safe", false], state),
    do: Map.get(state, :safe_block, %{"number" => "0x20", "hash" => @safe_hash})

  defp result("eth_getBlockByNumber", [number, false], state),
    do:
      state
      |> Map.get(:blocks, %{})
      |> Map.get(number, %{"number" => number, "hash" => @receipt_block_hash})

  defp result("eth_getTransactionReceipt", [hash], state),
    do: state |> Map.get(:receipts, %{}) |> Map.get(hash)

  defp result("eth_getTransactionByHash", [hash], state),
    do: state |> Map.get(:transactions, %{}) |> Map.get(hash)

  defp result("eth_call", [%{data: data}, _block], state), do: state.calls.(data, state)

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
