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
    @block %{
      "number" => "0x96",
      "hash" => "0x" <> String.duplicate("cd", 32),
      "timestamp" => "0x6700"
    }

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

  # An open auction with a tick at every whole price from the floor (1) to
  # 700, clearing at 400. A bid's tick walk starts at the lowest price above
  # the clearing price, so the 400 prices below it are never read.
  defmodule BusyStub do
    @block %{
      "number" => "0x12c",
      "hash" => "0x" <> String.duplicate("ce", 32),
      "timestamp" => "0x6700"
    }
    @spacing 2 ** 96
    @last_tick 2 ** 256 - 1

    def install do
      previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
      Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
          else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
      end)
    end

    def price(whole), do: whole * @spacing

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      {:ok, %{status: 200, body: %{"result" => answer(method, params)}}}
    end

    defp answer("eth_chainId", _params), do: "0x2105"
    defp answer("eth_getBlockByNumber", _params), do: @block
    defp answer("eth_getCode", _params), do: "0x6080"

    defp answer("eth_call", [%{data: "0x" <> <<selector::binary-size(8), argument::binary>>}, _]) do
      words =
        if "0x" <> selector == LabAbi.selector("ticks(uint256)"),
          do: [next_tick(String.to_integer(argument, 16)), 1],
          else: Map.fetch!(fixed(), "0x" <> selector)

      "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    end

    # Every whole price from 1 to 700 is a tick; 700 is the highest.
    defp next_tick(price) do
      whole = div(price, @spacing)

      cond do
        rem(price, @spacing) != 0 or whole not in 1..700 -> 0
        whole == 700 -> @last_tick
        true -> price + @spacing
      end
    end

    defp fixed do
      %{
        LabAbi.selector("currency()") => [0x3333333333333333333333333333333333333333],
        LabAbi.selector("balanceOf(address)") => [10 ** 18],
        LabAbi.selector("allowance(address,address)") => [0],
        LabAbi.selector("allowance(address,address,address)") => [0, 0, 0],
        LabAbi.selector("tickSpacing()") => [@spacing],
        LabAbi.selector("floorPrice()") => [@spacing],
        LabAbi.selector("startBlock()") => [200],
        LabAbi.selector("checkpoint()") => [price(400), 0, 0, 0, 0, 2 ** 64 - 1],
        LabAbi.selector("MAX_BID_PRICE()") => [price(10_000)],
        LabAbi.selector("nextActiveTickPrice()") => [price(401)]
      }
    end
  end

  test "a Base auction before its start block is not open for bids, not unreadable" do
    ChainStub.install()

    assert {:error, :bid_preparation_unavailable} =
             LabBidChainClient.snapshot(%{auction: @auction, signer: @signer, max_price_q96: nil})
  end

  test "a bid in a busy auction names the tick just below its price, however many lie below" do
    BusyStub.install()

    assert {:ok, %{prev_tick_price_q96: hint}} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: BusyStub.price(650)
             })

    assert hint == BusyStub.price(649)
  end

  test "a bid further up than one walk reaches names the highest tick the walk reached" do
    BusyStub.install()

    assert {:ok, %{prev_tick_price_q96: hint}} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: BusyStub.price(690)
             })

    assert hint == BusyStub.price(401 + Autolaunch.Chain.CcaLists.reads())
  end
end
