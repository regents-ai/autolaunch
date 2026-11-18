defmodule Autolaunch.LabBidChainClientTest do
  use ExUnit.Case, async: false

  alias Autolaunch.{BaseRpcStub, LabAbi, LabBidChainClient}

  @moduletag :capture_log

  @signer "0x" <> String.duplicate("11", 20)
  @auction "0x" <> String.duplicate("22", 20)

  # An auction from block 200 to 400, with a tick at every whole price from
  # the floor (1) to 700, and Base's latest block at `head` (300 unless a test
  # says otherwise). Open, it clears at 400, and a bid's tick walk starts at the
  # lowest price above that, so the 400 prices below it are never read. Before
  # its start it refuses `checkpoint()`, as the auction does, and its stored
  # clearing price is the floor.
  defmodule AuctionStub do
    @spacing 2 ** 96
    @last_tick 2 ** 256 - 1
    @start 200

    def install(head \\ 300) do
      previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
      Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)
      Application.put_env(:autolaunch, __MODULE__, head)

      ExUnit.Callbacks.on_exit(fn ->
        Application.delete_env(:autolaunch, __MODULE__)

        if previous,
          do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
          else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
      end)
    end

    def price(whole), do: whole * @spacing

    def post(_url, options) do
      %{method: method, params: params} = options[:json]

      case answer(method, params, Application.fetch_env!(:autolaunch, __MODULE__)) do
        :reverted ->
          {:ok, %{status: 200, body: %{"error" => %{"message" => "execution reverted"}}}}

        result ->
          {:ok, %{status: 200, body: %{"result" => result}}}
      end
    end

    defp answer("eth_chainId", _params, _head), do: "0x2105"

    defp answer("eth_getBlockByNumber", _params, head),
      do: %{
        "number" => "0x" <> Integer.to_string(head, 16),
        "hash" => "0x" <> String.duplicate("ce", 32),
        "timestamp" => "0x6700"
      }

    defp answer("eth_getCode", _params, _head), do: "0x6080"

    defp answer(
           "eth_call",
           [%{data: "0x" <> <<selector::binary-size(8), argument::binary>>}, _],
           head
         ) do
      cond do
        "0x" <> selector == LabAbi.selector("ticks(uint256)") ->
          words([next_tick(String.to_integer(argument, 16)), 1])

        "0x" <> selector == LabAbi.selector("checkpoint()") and head < @start ->
          :reverted

        true ->
          words(Map.fetch!(fixed(), "0x" <> selector))
      end
    end

    defp words(words), do: "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)

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
        LabAbi.selector("startBlock()") => [@start],
        LabAbi.selector("endBlock()") => [400],
        LabAbi.selector("checkpoint()") => [price(400), 0, 0, 0, 0, 2 ** 64 - 1],
        LabAbi.selector("clearingPrice()") => [@spacing],
        LabAbi.selector("MAX_BID_PRICE()") => [price(10_000)],
        LabAbi.selector("nextActiveTickPrice()") => [price(401)]
      }
    end
  end

  # The auction takes a bid from its start block on (`_onlyActiveAuction`), and a
  # step prepared at the latest block lands in the next one at the earliest.
  test "two blocks before a Base auction's start a bid is not open, not unreadable: it cannot land in time" do
    AuctionStub.install(198)

    assert {:error, :bid_preparation_unavailable} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: AuctionStub.price(650)
             })
  end

  test "the block before a Base auction's start a bid is read at the floor, since it lands in the start block at the earliest" do
    AuctionStub.install(199)

    assert {:ok, %{clearing_price_q96: clearing, block: %{number: 199}, end_block: 400}} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: AuctionStub.price(650)
             })

    assert clearing == AuctionStub.price(1)
  end

  test "a bid in a busy auction names the tick just below its price, however many lie below" do
    AuctionStub.install()

    # The auction's own end block comes with the block the snapshot read.
    assert {:ok, %{prev_tick_price_q96: hint, end_block: 400, block: %{number: 300}}} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: AuctionStub.price(650)
             })

    assert hint == AuctionStub.price(649)
  end

  test "a bid further up than one walk reaches names the highest tick the walk reached" do
    AuctionStub.install()

    assert {:ok, %{prev_tick_price_q96: hint}} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: AuctionStub.price(690)
             })

    assert hint == AuctionStub.price(401 + Autolaunch.Chain.CcaLists.reads())
  end
end
