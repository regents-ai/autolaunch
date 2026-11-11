defmodule Autolaunch.CoveredCalls.BookTest do
  @moduledoc """
  The shared reading of a market is kept between visits, and a covered-call
  step that lands drops it, so the next read shows what the step changed. It
  carries the market's bids beside its listings. A wallet's positions never
  come from the kept reading, and carry its own bids with what a refund would
  send it now.
  """
  use ExUnit.Case, async: false

  alias Autolaunch.CoveredCalls.{Book, Positions}
  alias Autolaunch.CoveredCallsChain

  @unit CoveredCallsChain.unit()

  setup do
    previous = Application.get_env(:autolaunch, :covered_calls_book_kept_ms)
    Application.put_env(:autolaunch, :covered_calls_book_kept_ms, 300_000)
    :ok = Book.expire("AMZNc")

    on_exit(fn ->
      :ok = Book.expire("AMZNc")

      if previous,
        do: Application.put_env(:autolaunch, :covered_calls_book_kept_ms, previous),
        else: Application.delete_env(:autolaunch, :covered_calls_book_kept_ms)
    end)
  end

  test "a kept reading stays until a landed step drops it" do
    CoveredCallsChain.install()
    {:ok, before} = Book.read("AMZNc")
    assert [%{filled: filled}] = before.listings
    assert filled == 4 * @unit

    CoveredCallsChain.put(%{listings: [CoveredCallsChain.listing(%{filled: 5 * @unit})]})
    assert {:ok, %{listings: [%{filled: ^filled}]}} = Book.read("AMZNc")

    :ok = Book.expire("AMZNc")
    assert {:ok, %{listings: [%{filled: refilled}]}} = Book.read("AMZNc")
    assert refilled == 5 * @unit
  end

  test "a crowd asking to read again keeps a fresh reading: one read per ten seconds" do
    CoveredCallsChain.install()
    {:ok, %{chain_id: chain_id}} = Autolaunch.CoveredCalls.Deployment.current()
    {:ok, before} = Book.read("AMZNc")
    assert [%{filled: filled}] = before.listings

    CoveredCallsChain.put(%{listings: [CoveredCallsChain.listing(%{filled: 5 * @unit})]})
    for _visitor <- 1..5, do: Book.refresh(chain_id)
    assert {:ok, %{listings: [%{filled: ^filled}]}} = Book.read("AMZNc")
  end

  test "a wallet's positions are read at the latest block, never from the kept reading" do
    CoveredCallsChain.install()
    {:ok, kept} = Book.read("AMZNc")
    assert length(kept.listings) == 1

    # Someone lists again and the wallet buys into both, with no press on this site.
    CoveredCallsChain.put(%{
      listings: [CoveredCallsChain.listing(%{}), CoveredCallsChain.listing(%{filled: @unit})],
      held: @unit
    })

    wallet = "0x" <> String.duplicate("ab", 20)
    assert {:ok, positions} = Positions.read("AMZNc", wallet)
    assert Enum.map(positions.book.listings, & &1.id) == [1, 2]
    assert Enum.map(positions.holdings, & &1.listing_id) == [1, 2]
    assert {:ok, %{listings: [_only]}} = Book.read("AMZNc")
  end

  test "the shared reading carries every bid beside the listings, read once for every visitor" do
    bids = [
      CoveredCallsChain.bid(%{}),
      CoveredCallsChain.bid(%{amount: 0, filled: 0, min_sale: 2 * @unit})
    ]

    CoveredCallsChain.install(%{bids: bids})
    {:ok, reading} = Book.read("AMZNc")

    assert [open, cancelled] = reading.bids
    assert open.id == 1 and cancelled.id == 2
    assert open.bidder == "0x3333333333333333333333333333333333333333"
    assert {open.amount, open.filled, open.min_sale} == {10 * @unit, 4 * @unit, @unit}
    assert {open.strike_per_token, open.premium_per_token} == {260_000_000, 3_000_000}
    assert open.expiry == hd(Autolaunch.CoveredCalls.Terms.expiries(CoveredCallsChain.now()))
    assert cancelled.min_sale == 2 * @unit

    # A bid posted after the reading waits for the next one, as a listing does.
    CoveredCallsChain.put(%{bids: bids ++ [CoveredCallsChain.bid(%{})]})
    assert {:ok, %{bids: [_one, _two]}} = Book.read("AMZNc")
  end

  test "a wallet's positions carry its own bids with what a refund would send it now" do
    wallet = "0x" <> String.duplicate("ab", 20)

    CoveredCallsChain.install(%{
      bids: [
        CoveredCallsChain.bid(%{bidder: wallet, refund_due: 6_000_000, refundable: 6_000_000}),
        CoveredCallsChain.bid(%{}),
        CoveredCallsChain.bid(%{bidder: wallet, refundable: 18_000_000})
      ]
    })

    assert {:ok, positions} = Positions.read("AMZNc", wallet)
    assert [%{id: 1, refundable: 6_000_000}, %{id: 3, refundable: 18_000_000}] = positions.bids
    assert length(positions.book.bids) == 3
  end

  test "a sale into a bid is the seller's sold listing and the bidder's held calls" do
    seller = "0x" <> String.duplicate("5e", 20)
    bidder = "0x" <> String.duplicate("b1", 20)

    # sellToBid opened listing 1, all of it filled, held by the bidder.
    sold = CoveredCallsChain.listing(%{seller: seller, amount: 4 * @unit, filled: 4 * @unit})

    CoveredCallsChain.install(%{
      listings: [sold],
      bids: [CoveredCallsChain.bid(%{bidder: bidder, filled: 4 * @unit})]
    })

    assert {:ok, %{sold: [%{id: 1, seller: ^seller}], holdings: []}} =
             Positions.read("AMZNc", seller)

    CoveredCallsChain.put(%{
      listings: [sold],
      bids: [CoveredCallsChain.bid(%{bidder: bidder, filled: 4 * @unit})],
      held: 4 * @unit
    })

    assert {:ok, %{sold: [], holdings: [%{listing_id: 1, held: held}], bids: [%{id: 1}]}} =
             Positions.read("AMZNc", bidder)

    assert held == 4 * @unit
  end
end
