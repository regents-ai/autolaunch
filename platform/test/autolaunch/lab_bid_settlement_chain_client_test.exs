defmodule Autolaunch.LabBidSettlementChainClientTest do
  @moduledoc """
  A partly filled bid in an auction with a long price history. Its checkpoint
  hints lie hundreds of checkpoints after its own, and the auction itself (the
  simulation below) accepts only the exact ones.
  """
  use ExUnit.Case, async: false

  alias Autolaunch.{BaseRpcStub, LabAbi, LabBidSettlementChainClient}

  @moduletag :capture_log

  @signer "0x" <> String.duplicate("11", 20)

  # A checkpoint at every block from 100 to 700: priced 5 until block 499, 10
  # (the bid's maximum) until 549 and 12 from 550, where bidding ended. Bid 0
  # is the one settled; `bids` names the start block of every bid.
  defmodule HistoryStub do
    @block %{
      "number" => "0x3e8",
      "hash" => "0x" <> String.duplicate("cf", 32),
      "timestamp" => "0x6700"
    }
    @spacing 2 ** 96
    @last_block 2 ** 64 - 1
    @owner 0x1111111111111111111111111111111111111111

    def install(bids) do
      previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
      Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)
      Application.put_env(:autolaunch, __MODULE__, bids)

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
      {:ok, %{status: 200, body: %{"result" => answer(method, params)}}}
    end

    defp answer("eth_chainId", _params), do: "0x2105"
    defp answer("eth_getBlockByNumber", _params), do: @block
    defp answer("eth_getCode", _params), do: "0x6080"

    defp answer("eth_call", [%{to: auction, data: data}, _block]) do
      {selector, arguments} = split(data)
      "0x" <> Enum.map_join(read(selector, arguments, auction), &BaseRpcStub.hex_word/1)
    end

    defp answer("eth_simulateV1", [%{blockStateCalls: [%{calls: calls}]}, _block]),
      do: [%{"calls" => Enum.map(calls, &simulated/1)}]

    defp read("bids(uint256)", [id], _auction) do
      start = Enum.at(bids(), id)
      [start, 0, 0, price(10), @owner, 10 ** 18 * @spacing, 0]
    end

    defp read("checkpoints(uint64)", [block], _auction) when block in 100..700 do
      next = if block == 700, do: @last_block, else: block + 1
      [checkpoint_price(block), 0, 0, 0, block - 1, next]
    end

    defp read("checkpoints(uint64)", [_block], _auction), do: [0, 0, 0, 0, 0, 0]
    defp read("nextBidId()", [], _auction), do: [length(bids())]
    defp read("endBlock()", [], _auction), do: [700]
    defp read("claimBlock()", [], _auction), do: [800]
    defp read("currency()", [], _auction), do: [0x3333333333333333333333333333333333333333]

    defp checkpoint_price(block) when block < 500, do: price(5)
    defp checkpoint_price(block) when block < 550, do: price(10)
    defp checkpoint_price(_block), do: price(12)

    defp simulated(%{to: auction, data: data}) do
      case split(data) do
        {"checkpoint()", []} ->
          success(nil)

        {"isGraduated()", []} ->
          success(1)

        {"clearingPrice()", []} ->
          success(price(12))

        {"currencyRaised()", []} ->
          success(10 ** 20)

        {"exitBid(uint256)", [0]} ->
          reverted("CannotExitBid()")

        {"claimTokens(uint256)", [0]} ->
          reverted("NotClaimable()")

        {"exitPartiallyFilledBid(uint256,uint64,uint64)", [0, 499, 550]} ->
          exited(auction)

        {"exitPartiallyFilledBid(uint256,uint64,uint64)", _hints} ->
          reverted("InvalidLastFullyFilledCheckpointHint()")
      end
    end

    defp success(nil), do: %{"status" => "0x1", "returnData" => "0x", "logs" => []}

    defp success(word),
      do: %{"status" => "0x1", "returnData" => "0x" <> BaseRpcStub.hex_word(word), "logs" => []}

    defp reverted(error),
      do: %{"status" => "0x0", "returnData" => LabAbi.selector(error), "logs" => []}

    defp exited(auction) do
      log = %{
        "address" => auction,
        "topics" => [
          LabAbi.topic("BidExited(uint256,address,uint256,uint256)"),
          "0x" <> BaseRpcStub.hex_word(0),
          "0x" <> BaseRpcStub.hex_word(@owner)
        ],
        "data" => "0x" <> BaseRpcStub.hex_word(4 * 10 ** 18) <> BaseRpcStub.hex_word(10 ** 18)
      }

      %{"status" => "0x1", "returnData" => "0x", "logs" => [log]}
    end

    defp bids, do: Application.fetch_env!(:autolaunch, __MODULE__)

    @signatures [
      "bids(uint256)",
      "checkpoints(uint64)",
      "nextBidId()",
      "endBlock()",
      "claimBlock()",
      "currency()",
      "checkpoint()",
      "isGraduated()",
      "clearingPrice()",
      "currencyRaised()",
      "exitBid(uint256)",
      "claimTokens(uint256)",
      "exitPartiallyFilledBid(uint256,uint64,uint64)"
    ]

    defp split("0x" <> <<selector::binary-size(8), arguments::binary>>) do
      signature = Enum.find(@signatures, &(LabAbi.selector(&1) == "0x" <> selector))
      {signature, for(<<word::binary-size(64) <- arguments>>, do: String.to_integer(word, 16))}
    end
  end

  test "a partly filled bid hundreds of checkpoints from its crossing is settled with the exact hints" do
    HistoryStub.install([100, 300, 500, 550])

    assert {:ok, %{exit: exit}} = snapshot("0x" <> String.duplicate("a1", 20))
    assert exit.signature == "exitPartiallyFilledBid(uint256,uint64,uint64)"
    assert exit.hints == %{last_fully_filled_block: 499, outbid_block: 550}
    assert exit.currency_refunded == 10 ** 18
  end

  # The outbid walk went back to the bid's own checkpoint and read the whole
  # stretch again, so this took a third request (review of the money-path
  # fixes, 12 Nov 2026).
  test "a stretch longer than one request's reads is read across requests, and the outbid walk goes on from the filled one" do
    HistoryStub.install([100, 550])
    auction = "0x" <> String.duplicate("a2", 20)

    assert {:ok, %{exit: {:refused, :price_history_long}}} = snapshot(auction)

    assert {:ok, %{exit: %{hints: %{last_fully_filled_block: 499, outbid_block: 550}}}} =
             snapshot(auction)
  end

  defp snapshot(auction),
    do: LabBidSettlementChainClient.snapshot(%{auction: auction, bid_id: 0, signer: @signer})
end
