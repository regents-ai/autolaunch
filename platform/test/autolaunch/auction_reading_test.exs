defmodule Autolaunch.AuctionReadingTest do
  use Autolaunch.DataCase, async: false
  use ExUnitProperties

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionReading.Page
  alias Autolaunch.TestSupport

  @word 2 ** 256 - 1

  # Every price an auction page shows is a whole Q96 number up to 2^256, and
  # the ladder packs every price it read into one binary. A page must come back
  # from its row exactly as it was read, or a bidder sees another price.
  property "a page is stored and read back exactly, up to a thousand prices" do
    check all(page <- page(0..1_000), max_runs: 25) do
      auction = TestSupport.project_auction(chain_id: 8453, state: :active)
      {:ok, reading} = record(auction, page)
      {:ok, stored} = Autolaunch.get_auction_reading(auction.id, actor: nil)

      assert dumped(stored.page) == dumped(reading.page)
      assert dumped(stored.page) == page |> cast() |> dumped()
    end
  end

  test "a page larger than a reading holds is not stored" do
    auction = TestSupport.project_auction(chain_id: 8453, state: :active)
    [page] = Enum.take(page(3_000..3_000), 1)

    assert {:error, %Ash.Error.Invalid{}} = record(auction, page)
    assert {:ok, nil} = Autolaunch.get_auction_reading(auction.id, actor: nil)
  end

  defp record(auction, page) do
    Autolaunch.record_auction_reading(
      %{
        auction_id: auction.id,
        read_block: page.block.number,
        block_hash: page.block.hash,
        read_at: DateTime.utc_now(),
        market: %{start_block: 100, end_block: 200, currency_raised: "1"},
        page: page
      },
      actor: %System{}
    )
  end

  defp cast(page) do
    {:ok, page} = Ash.Type.cast_input(Page, page, [])
    page
  end

  defp dumped(page) do
    {:ok, dumped} = Ash.Type.dump_to_embedded(Page, page, [])
    dumped
  end

  defp page(read_range) do
    gen all(
          read <- integer(read_range),
          prices <- binary(length: read * 64),
          rungs <- list_of(rung(), max_length: min(read, 100)),
          clearing <- integer(0..@word),
          to_beat <- one_of([constant(nil), integer(0..@word)]),
          number <- integer(1..1_000_000),
          stage <- member_of([:created, :open, :finishing, :pool_ready, :failed]),
          locked <- one_of([constant(nil), boolean()]),
          complete? <- boolean()
        ) do
      %{
        block: %{number: number, hash: "0x" <> String.duplicate("ab", 32), timestamp: number},
        clearing_q96: clearing,
        clearing: "1.5",
        decimals: 18,
        tick_spacing_q96: div(2 ** 96, 100),
        max_bid_price_q96: @word,
        price_to_beat_q96: to_beat,
        price_to_beat: to_beat && "1.51",
        address: "0x" <> String.duplicate("cd", 20),
        clock: number,
        blocks: %{start: 100, end: 200, claim: 210, supply: @word, cleared: 0, raised: @word},
        schedule: [%{from: 100, to: 200, mps: 100_000}],
        ladder: %{
          state: %{
            checkpoint_block: number,
            clearing_q96: clearing,
            remaining_mps: 5_000_000,
            remaining_supply_q96x7: @word,
            demand_above_q96: @word
          },
          complete?: complete?,
          rungs: rungs,
          more: max(read - 100, 0),
          highest_q96: if(read > 0, do: @word),
          prices: prices
        },
        stage: %{
          stage: stage,
          facts: %{
            minimum_reached: true,
            claims_open: false,
            refunds_open: false,
            liquidity_locked: locked
          }
        },
        raised: "1"
      }
    end
  end

  defp rung do
    gen all(price <- integer(0..@word)) do
      %{price_q96: price, price: "2", bidding: "0.5", needed: "10"}
    end
  end
end
