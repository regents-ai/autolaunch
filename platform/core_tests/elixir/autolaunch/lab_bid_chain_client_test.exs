defmodule Autolaunch.LabBidChainClientTest do
  use ExUnit.Case, async: false

  alias Autolaunch.{BaseRpcStub, LabAbi, LabBidChainClient}

  @moduletag :capture_log

  @signer "0x" <> String.duplicate("11", 20)
  @auction "0x" <> String.duplicate("22", 20)

  # A Base head at block 150 and an auction that opens at block 200. The
  # auction refuses `checkpoint()` before its start, so answering it here would
  # hide the start-block check behind a chain that looks unreadable.
  defmodule ChainStub do
    @block %{"number" => "0x96", "hash" => "0x" <> String.duplicate("cd", 32)}

    def install do
      previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
      Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
          else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
      end)
    end

    def post(_url, options) do
      %{method: method, params: params} = options[:json]

      case answer(method, params) do
        :refused -> {:ok, %{status: 200, body: %{"error" => %{"message" => "refused"}}}}
        result -> {:ok, %{status: 200, body: %{"result" => result}}}
      end
    end

    defp answer("eth_chainId", _params), do: "0x2105"
    defp answer("eth_getBlockByNumber", _params), do: @block
    defp answer("eth_getCode", _params), do: "0x6080"

    defp answer("eth_call", [%{data: data}, _block]) do
      case Map.fetch(words(), String.slice(data, 0, 10)) do
        {:ok, words} -> "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
        :error -> :refused
      end
    end

    defp words do
      %{
        LabAbi.selector("currency()") => [0x3333333333333333333333333333333333333333],
        LabAbi.selector("balanceOf(address)") => [10 ** 18],
        LabAbi.selector("allowance(address,address)") => [0],
        LabAbi.selector("allowance(address,address,address)") => [0, 0, 0],
        LabAbi.selector("tickSpacing()") => [2 ** 96],
        LabAbi.selector("floorPrice()") => [2 ** 96],
        LabAbi.selector("startBlock()") => [200]
      }
    end
  end

  test "a Base auction before its start block is not open for bids, not unreadable" do
    ChainStub.install()

    assert {:error, :bid_preparation_unavailable} =
             LabBidChainClient.snapshot(%{auction: @auction, signer: @signer, max_price_q96: nil})
  end
end
