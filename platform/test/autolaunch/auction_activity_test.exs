defmodule Autolaunch.AuctionActivityTest do
  # Sean agreed the first test on 5 Nov 2026. The reader raised before saving on
  # every pass over an auction already open, from 31 Oct to 4 Nov, because a start
  # block in the past counts as negative seconds. The others prove the 10 Nov
  # audit fix: a lagging node waits instead of wiping history, a real reorg still
  # rebuilds, and the totals are written only by a pass that reached the head.
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]

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
  alias Autolaunch.Stocks.MarketData

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
  @opened 1_799_990_000
  @atomic 2_000_000_000_000_000_000
  @q96 79_228_162_514_264_337_593_543_950_336

  # The stub answers every log filter alike; the chain answers only the auction's.
  # The auction's code is there from the first block on.
  defmodule Transport do
    @moduledoc false
    alias Autolaunch.BaseRpcStub

    def post(url, options) do
      case options[:json] do
        %{method: "eth_getCode"} ->
          {:ok, %{status: 200, body: %{"result" => "0x01"}}}

        %{method: "eth_getLogs", params: [%{address: address}]} ->
          logs = if address == BaseRpcStub.state().auction, do: BaseRpcStub.state().logs, else: []
          {:ok, %{status: 200, body: %{"result" => logs}}}

        _request ->
          BaseRpcStub.post(url, options)
      end
    end
  end

  # REGENT at fifty cents, from the pool DexScreener lists for it.
  defmodule PricedMarket do
    @moduledoc false
    alias Autolaunch.Chain.Abi

    def get(url, _options) do
      if String.contains?(url, "/latest/dex/pairs/base/") do
        pair = %{"baseToken" => %{"address" => Abi.regent_address()}, "priceUsd" => "0.5"}
        {:ok, %{status: 200, body: %{"pairs" => [pair]}}}
      else
        {:ok, %{status: 503, body: %{}}}
      end
    end
  end

  setup do
    previous = Application.get_env(:autolaunch, :autolaunch_market_http_client)
    MarketData.reset()

    on_exit(fn ->
      Application.put_env(:autolaunch, :autolaunch_market_http_client, previous)
      MarketData.reset()
    end)

    %{market: previous}
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
    assert DateTime.to_unix(saved.opened_at) == @opened
    assert DateTime.to_unix(saved.estimated_end_at) == @now + 200
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

  test "a node answering behind the saved cursor waits and keeps the saved history" do
    auction = first_pass()

    lagging = block(@head - 100, "0x" <> String.duplicate("3c", 32))
    put_blocks(%{"latest" => lagging, hex(@head - 100) => lagging})

    assert {{:snooze, 60}, _log} = with_log(fn -> pass(auction) end)

    saved = Ash.get!(Auction, auction.id, actor: %System{})
    assert saved.activity_next_block == @head + 1
    assert saved.activity_last_hash == @head_hash
    assert Decimal.equal?(saved.bid_volume, 2)
    assert [%{bid_id: "7"}] = Autolaunch.auction_bids!(auction.id)
    assert [%{block_number: @bid_block}] = Autolaunch.auction_price_points!(auction.id)
  end

  test "a different block at the saved cursor still clears the history to rebuild it" do
    auction = first_pass()

    reorged = block(@head, "0x" <> String.duplicate("3d", 32))
    put_blocks(%{"latest" => reorged, hex(@head) => reorged})

    assert {:snooze, 1} = pass(auction)

    saved = Ash.get!(Auction, auction.id, actor: %System{})
    assert saved.activity_next_block == nil
    assert saved.bid_volume == nil
    assert Autolaunch.auction_bids!(auction.id) == []
    assert Autolaunch.auction_price_points!(auction.id) == []
  end

  test "a pass that has not reached the head leaves the totals as stored" do
    priced_market()
    auction = first_pass()
    assert Decimal.equal?(Ash.get!(Auction, auction.id, actor: %System{}).bid_volume_usd, 1)

    far = block(@head + 5_000, "0x" <> String.duplicate("3e", 32))
    put_blocks(%{"latest" => far, hex(@head + 5_000) => far})
    BaseRpcStub.put(%{logs: []})

    assert {:snooze, 1} = pass(auction)

    saved = Ash.get!(Auction, auction.id, actor: %System{})
    assert saved.activity_next_block == @head + 2_001
    assert Decimal.equal?(saved.bid_volume, 2)
    assert Decimal.equal?(saved.bid_volume_usd, 1)
  end

  test "a pass that reached the head with no dollar rate blanks the dollar total", %{
    market: market
  } do
    priced_market()
    auction = first_pass()
    assert Decimal.equal?(Ash.get!(Auction, auction.id, actor: %System{}).bid_volume_usd, 1)

    # REGENT's price stops answering; a new bid lands at the head.
    Application.put_env(:autolaunch, :autolaunch_market_http_client, market)
    MarketData.reset()

    BaseRpcStub.put(%{
      logs: [
        log(
          0,
          [
            topic("BidSubmitted(uint256,address,uint256,uint128)"),
            BaseRpcStub.uint(8),
            BaseRpcStub.address_topic(@bidder)
          ],
          [@q96, @atomic],
          @head
        )
      ]
    })

    assert {:snooze, 300} = pass(auction)

    saved = Ash.get!(Auction, auction.id, actor: %System{})
    assert Decimal.equal?(saved.bid_volume, 4)
    assert saved.bid_volume_usd == nil
  end

  # AL-ROBINHOOD-DATES: an ended Robinhood auction's dates moved on every pass,
  # because they were worked out from the newest block at ten blocks a second
  # though both blocks were already made and carry their own times.
  test "a Robinhood auction's blocks already made give its dates their own times" do
    chain_id = 4_663
    put_env(:autolaunch_robinhood_chain_id, chain_id)

    put_env(
      :autolaunch_robinhood_deployment,
      Path.expand("../fixtures/robinhood-deployment.json", __DIR__)
    )

    install(chain_id)
    ended = @head - 20

    BaseRpcStub.put(%{logs: [], end_block: ended})
    put_blocks(%{hex(ended) => block(ended, @bid_hash)})

    auction =
      Autolaunch.TestSupport.project_auction(
        chain_id: chain_id,
        kind: :stocks,
        address: @auction,
        state: :active
      )

    assert {:snooze, 300} = pass(auction)

    # The row itself: the plain read of an auction leaves Robinhood's out.
    saved = Repo.one!(from a in Auction, where: a.id == ^auction.id)
    assert DateTime.to_unix(saved.opened_at) == @opened
    assert DateTime.to_unix(saved.estimated_end_at) == @now - 20
  end

  defp put_env(key, value) do
    previous = Application.get_env(:autolaunch, key)
    Application.put_env(:autolaunch, key, value)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, key, previous),
        else: Application.delete_env(:autolaunch, key)
    end)
  end

  defp first_pass do
    chain_id = Lab.current!().chain_id
    install(chain_id)

    auction =
      Autolaunch.TestSupport.project_auction(
        chain_id: chain_id,
        address: @auction,
        state: :active
      )

    assert {:snooze, 300} = pass(auction)
    auction
  end

  defp pass(auction), do: perform_job(AuctionActivity, %{auction_id: auction.id})

  defp priced_market,
    do: Application.put_env(:autolaunch, :autolaunch_market_http_client, PricedMarket)

  defp put_blocks(blocks),
    do: BaseRpcStub.put(%{blocks: Map.merge(BaseRpcStub.state().blocks, blocks)})

  defp block(number, hash),
    do: %{"number" => hex(number), "hash" => hash, "timestamp" => hex(@now + number - @head)}

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
        hex(@start_block) => %{
          "number" => hex(@start_block),
          "hash" => @bid_hash,
          "timestamp" => hex(@opened)
        },
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

  # Robinhood's contracts keep time by the rollup's block, here the head's.
  defp call(%{data: data}, state) do
    cond do
      data == LabAbi.selector("startBlock()") -> BaseRpcStub.uint(@start_block)
      data == LabAbi.selector("endBlock()") -> BaseRpcStub.uint(state[:end_block] || @end_block)
      data == LabAbi.selector("arbBlockNumber()") -> BaseRpcStub.uint(@head)
      data == LabAbi.selector("currencyRaised()") -> BaseRpcStub.uint(@atomic)
    end
  end

  defp log(index, topics, words, number \\ @bid_block) do
    %{
      "address" => @auction,
      "blockNumber" => hex(number),
      "blockHash" => if(number == @head, do: @head_hash, else: @bid_hash),
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
