defmodule Autolaunch.AuctionActivityTest do
  # Sean agreed this one test on 5 Nov 2026. The reader raised before saving on
  # every pass over an auction already open, from 31 Oct to 4 Nov, because a start
  # block in the past counts as negative seconds. Nothing else runs a pass.
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo

  import Ecto.Query, only: [from: 2]

  alias Autolaunch.{
    Auction,
    AuctionActivity,
    BaseRpcStub,
    Bid,
    Lab,
    LabAbi,
    Repo
  }

  alias Autolaunch.Actors.System

  @auction "0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  @bidder "0x1414141414141414141414141414141414141414"
  @transaction "0x" <> String.duplicate("4d", 32)
  @head_hash "0x" <> String.duplicate("5a", 32)
  @bid_hash "0x" <> String.duplicate("7b", 32)
  @head 1_000
  @bid_block 950
  @start_block 900
  @end_block 2_000
  @now 1_800_000_000
  @atomic 2_000_000_000_000_000_000
  @q96 79_228_162_514_264_337_593_543_950_336

  # The stub answers every log filter alike; the chain answers only the auction's.
  defmodule Transport do
    @moduledoc false
    alias Autolaunch.BaseRpcStub

    def post(url, options) do
      case options[:json] do
        %{method: "eth_getLogs", params: [%{address: address}]} ->
          logs = if address == BaseRpcStub.state().auction, do: BaseRpcStub.state().logs, else: []
          {:ok, %{status: 200, body: %{"result" => logs}}}

        _request ->
          BaseRpcStub.post(url, options)
      end
    end
  end

  test "a pass over an open auction with a past start block saves what the chain said" do
    chain_id = Lab.current!().chain_id
    install(chain_id)

    auction =
      Autolaunch.TestSupport.project_auction(
        chain_id: chain_id,
        address: @auction,
        state: :active
      )

    assert {:snooze, 300} = perform_job(AuctionActivity, %{auction_id: auction.id})

    saved = Ash.get!(Auction, auction.id, actor: %System{})
    assert saved.activity_next_block == @head + 1
    assert saved.activity_last_hash == @head_hash
    assert DateTime.to_unix(saved.opened_at) == @now - (@head - @start_block) * 2
    assert DateTime.to_unix(saved.estimated_end_at) == @now + (@end_block - @head) * 2
    assert Decimal.equal?(saved.bid_volume, 2)

    assert [%{bid_id: "7", bidder: @bidder, block_number: @bid_block} = bid] =
             Autolaunch.auction_bids!(auction.id)

    assert Decimal.equal?(bid.amount, 2)
    assert DateTime.to_unix(bid.occurred_at) == @now - 100

    assert [%{block_number: @bid_block, clock_block: @bid_block}] =
             Autolaunch.auction_price_points!(auction.id)

    # A saved position has no read without a signed-in wallet, so this reads the row back.
    assert [%{onchain_bid_id: "7", owner_address: @bidder}] =
             Repo.all(from b in Bid, where: b.auction_id == ^auction.id)
  end

  defp install(chain_id) do
    BaseRpcStub.install(:autolaunch_lab_http_client, &call/2)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, Transport)

    head = %{"number" => hex(@head), "hash" => @head_hash, "timestamp" => hex(@now)}

    BaseRpcStub.put(%{
      chain_id: hex(chain_id),
      auction: @auction,
      blocks: %{
        "latest" => head,
        hex(@head) => head,
        hex(@bid_block) => %{
          "number" => hex(@bid_block),
          "hash" => @bid_hash,
          "timestamp" => hex(@now - 100)
        }
      },
      logs: [
        log(0, [topic("CheckpointUpdated(uint256,uint256,uint24)")], [@bid_block, @q96, 0]),
        log(
          1,
          [
            topic("BidSubmitted(uint256,address,uint256,uint128)"),
            BaseRpcStub.uint(7),
            BaseRpcStub.address_topic(@bidder)
          ],
          [@q96, @atomic]
        )
      ]
    })
  end

  defp call(data, _state) do
    cond do
      data == LabAbi.selector("startBlock()") -> BaseRpcStub.uint(@start_block)
      data == LabAbi.selector("endBlock()") -> BaseRpcStub.uint(@end_block)
      data == LabAbi.selector("currencyRaised()") -> BaseRpcStub.uint(@atomic)
    end
  end

  defp log(index, topics, words) do
    %{
      "address" => @auction,
      "blockNumber" => hex(@bid_block),
      "blockHash" => @bid_hash,
      "transactionHash" => @transaction,
      "logIndex" => hex(index),
      "removed" => false,
      "topics" => topics,
      "data" => "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    }
  end

  defp topic(signature), do: LabAbi.topic(signature)
  defp hex(value), do: "0x" <> Integer.to_string(value, 16)
end
