defmodule Autolaunch.CoveredCalls.BookTest do
  @moduledoc """
  The shared reading of a market is kept between visits, and a covered-call
  step that lands drops it, so the next read shows what the step changed. It
  holds what the site offers: the best fifty open listings and open bids of
  each Friday it offers, with the count of all of each, and no listing or bid
  on another expiry or with less than a whole token left. Listings and bids
  are read many to a request; those that can never change again are read
  once, and a bid past its expiry only by its bidder. A wallet's positions
  never come from the kept reading, and carry its own listings and bids
  whatever their expiry, its bids with what a refund would send it now.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Autolaunch.CoveredCalls.{Answer, Book, Chain, Deployment, Positions, Terms}
  alias Autolaunch.CoveredCallsChain

  @unit CoveredCallsChain.unit()
  @now CoveredCallsChain.now()
  @wallet "0x" <> String.duplicate("ab", 20)

  setup do
    previous = Application.get_env(:autolaunch, :covered_calls_book_kept_ms)
    Application.put_env(:autolaunch, :covered_calls_book_kept_ms, 300_000)
    restart_book()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :covered_calls_book_kept_ms, previous),
        else: Application.delete_env(:autolaunch, :covered_calls_book_kept_ms)

      restart_book()
    end)
  end

  # A new book process keeps no reading and no settled record of an earlier test.
  defp restart_book do
    :ok = Supervisor.terminate_child(Autolaunch.Supervisor, Book)
    {:ok, _pid} = Supervisor.restart_child(Autolaunch.Supervisor, Book)
  end

  defp at_latest do
    {:ok, config} = Deployment.current()
    {:ok, market} = Deployment.market("AMZNc")
    {:ok, block, opts} = Chain.latest(config.lab)
    {market, block, opts}
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
    {:ok, %{chain_id: chain_id}} = Deployment.current()
    {:ok, before} = Book.read("AMZNc")
    assert [%{filled: filled}] = before.listings

    CoveredCallsChain.put(%{listings: [CoveredCallsChain.listing(%{filled: 5 * @unit})]})
    for _visitor <- 1..5, do: Book.refresh(chain_id)
    assert {:ok, %{listings: [%{filled: ^filled}]}} = Book.read("AMZNc")
  end

  test "visitors asking while a reading is taken wait for that one reading" do
    CoveredCallsChain.install(%{hold: self()})
    visitors = for _visitor <- 1..3, do: Task.async(fn -> Book.read("AMZNc") end)

    assert_receive {:held, reader}
    refute_receive {:held, _another}, 100

    CoveredCallsChain.put(%{})
    send(reader, :go)

    assert [{:ok, reading}, {:ok, reading}, {:ok, reading}] = Task.await_many(visitors)
    # One request for the counts and terms, one for the listings; there are no bids.
    assert CoveredCallsChain.requests() == 2
  end

  test "a step landing while a reading is taken drops that reading too" do
    CoveredCallsChain.install(%{hold: self()})
    visitor = Task.async(fn -> Book.read("AMZNc") end)
    assert_receive {:held, reader}

    :ok = Book.expire("AMZNc")
    CoveredCallsChain.put(%{})
    send(reader, :go)
    assert {:ok, _from_before_the_step} = Task.await(visitor)

    CoveredCallsChain.put(%{listings: [CoveredCallsChain.listing(%{filled: 6 * @unit})]})
    assert {:ok, %{listings: [%{filled: filled}]}} = Book.read("AMZNc")
    assert filled == 6 * @unit
  end

  property "listings and bids read many to a request are those read one by one" do
    CoveredCallsChain.install()

    check all(listings <- integer(0..450), bids <- integer(0..450), max_runs: 6) do
      CoveredCallsChain.put(%{
        listings: for(n <- 1..listings//1, do: CoveredCallsChain.listing(%{filled: n})),
        bids: for(n <- 1..bids//1, do: CoveredCallsChain.bid(%{filled: n, premium: 1_000 + n}))
      })

      {market, block, opts} = at_latest()
      before = CoveredCallsChain.requests()
      assert {:ok, book} = Chain.book(market, block, opts)
      requests = CoveredCallsChain.requests() - before

      assert book.listings ==
               for(id <- 1..listings//1, do: one(Chain.listing(market, id, block, opts)))

      assert book.bids == for(id <- 1..bids//1, do: one(Chain.bid(market, id, block, opts)))
      assert requests == 1 + batches(listings) + batches(bids)
    end
  end

  defp one({:ok, record}), do: record

  defp batches(count), do: div(count + 199, 200)

  test "the reading holds the best fifty open listings and bids with the count of all" do
    expiry = hd(Terms.expiries(@now))

    listings =
      for n <- 1..60, do: CoveredCallsChain.listing(%{strike: 260_000_000 + rem(n * 7, 60)})

    bids =
      for n <- 1..70, do: CoveredCallsChain.bid(%{premium: 1_000_000 + rem(n * 11, 70)})

    # One that sold out, one stopped and one past its expiry are not open.
    closed = [
      CoveredCallsChain.listing(%{filled: 10 * @unit}),
      CoveredCallsChain.listing(%{amount: 0, filled: 0}),
      CoveredCallsChain.listing(%{expiry: @now - 60})
    ]

    CoveredCallsChain.install(%{listings: listings ++ closed, bids: bids})
    {:ok, reading} = Book.read("AMZNc")

    assert {length(reading.listings), reading.listings_total} == {50, 60}
    assert {length(reading.bids), reading.bids_total} == {50, 70}
    assert Enum.all?(reading.listings, &(&1.expiry == expiry and &1.id <= 60))

    # The ten listings left out ask more than any shown; the twenty bids left out pay less.
    assert Enum.map(reading.listings, & &1.strike_per_token) ==
             Enum.map(0..49, &(260_000_000 + &1))

    assert Enum.map(reading.bids, & &1.premium_per_token) ==
             Enum.map(69..20//-1, &(1_000_000 + &1))
  end

  test "a bid with less than one whole token left is not offered, and is still its bidder's" do
    CoveredCallsChain.install(%{
      bids: [
        CoveredCallsChain.bid(%{bidder: @wallet, filled: 10 * @unit - (@unit - 1)}),
        CoveredCallsChain.bid(%{bidder: @wallet, filled: 9 * @unit}),
        CoveredCallsChain.bid(%{amount: 0, filled: 0})
      ]
    })

    assert {:ok, %{bids: [%{id: 2}], bids_total: 1}} = Book.read("AMZNc")
    assert {:ok, %{bids: [%{id: 1}, %{id: 2}]}} = Positions.read("AMZNc", @wallet)
  end

  # A Friday at 21:00 UTC in the year 10000, which the contract takes, and the
  # largest time it can hold.
  @far_friday 253_402_894_800
  @last_time 2 ** 64 - 1

  test "a listing or bid on a Friday the site doesn't offer is never offered, and is still its maker's" do
    far = %{seller: @wallet, bidder: @wallet, filled: 0}

    CoveredCallsChain.install(%{
      listings: [
        CoveredCallsChain.listing(Map.put(far, :expiry, @far_friday)),
        CoveredCallsChain.listing(Map.put(far, :expiry, @last_time)),
        CoveredCallsChain.listing(%{})
      ],
      bids: [
        CoveredCallsChain.bid(%{bidder: @wallet, expiry: @far_friday, premium: 1}),
        CoveredCallsChain.bid(%{bidder: @wallet, expiry: @last_time, refundable: 7}),
        CoveredCallsChain.bid(%{})
      ]
    })

    assert {:ok, reading} = Book.read("AMZNc")
    assert [%{id: 3}] = reading.listings
    assert [%{id: 3}] = reading.bids
    assert {reading.listings_total, reading.bids_total} == {1, 1}

    assert {:ok, positions} = Positions.read("AMZNc", @wallet)
    assert Enum.map(positions.sold, &{&1.id, &1.expiry}) == [{1, @far_friday}, {2, @last_time}]
    assert Enum.map(positions.bids, &{&1.id, &1.expiry}) == [{1, @far_friday}, {2, @last_time}]

    # Every agent surface sends these answers as JSON.
    for answer <- [Answer.book({:ok, reading}), Answer.positions({:ok, positions})] do
      assert {:ok, data} = answer
      assert is_binary(Jason.encode!(data))
    end
  end

  test "fifty bids on the nearest Friday leave a later Friday's bids offered" do
    [first, second | _later] = Terms.expiries(@now)

    near =
      for n <- 1..60, do: CoveredCallsChain.bid(%{premium: 5_000_000 + n, filled: 0})

    later = CoveredCallsChain.bid(%{expiry: second, premium: 1, filled: 0})
    CoveredCallsChain.install(%{listings: [], bids: near ++ [later]})

    assert {:ok, reading} = Book.read("AMZNc")
    assert reading.bids_total == 61
    assert Enum.count(reading.bids, &(&1.expiry == first)) == 50
    assert List.last(reading.bids).id == 61
  end

  test "fifty listings of one raw unit leave a real listing offered" do
    dust = for _n <- 1..50, do: CoveredCallsChain.listing(%{amount: 1, filled: 0, premium: 1})
    real = CoveredCallsChain.listing(%{premium: 9_000_000})
    CoveredCallsChain.install(%{listings: dust ++ [real]})

    assert {:ok, %{listings: [%{id: 51}], listings_total: 1}} = Book.read("AMZNc")
  end

  test "a bid past its expiry is read once by the shared reading, and only by its bidder after that" do
    past = @now - 3_600
    other = "0x" <> String.duplicate("cd", 20)

    CoveredCallsChain.install(%{
      listings: [],
      bids: [
        CoveredCallsChain.bid(%{bidder: other, expiry: past}),
        CoveredCallsChain.bid(%{bidder: @wallet, expiry: past, refundable: 5}),
        CoveredCallsChain.bid(%{bidder: other, expiry: @far_friday})
      ]
    })

    assert {:ok, %{bids: []}} = Book.read("AMZNc")
    assert {:ok, %{bids: [%{id: 2, refundable: 5}]}} = Positions.read("AMZNc", @wallet)

    # From now on the counts and terms are read, and only the bidder's own bid.
    before = CoveredCallsChain.requests()
    :ok = Book.expire("AMZNc")
    assert {:ok, %{bids: []}} = Book.read("AMZNc")
    assert CoveredCallsChain.requests() - before == 1

    before = CoveredCallsChain.requests()
    assert {:ok, %{bids: [%{id: 2}]}} = Positions.read("AMZNc", @wallet)
    # The counts and terms, the wallet's own bid, its refund, and the stock balance.
    assert CoveredCallsChain.requests() - before == 4
  end

  defp open_bid do
    gen all(
          id <- positive_integer(),
          week <- integer(0..2),
          strike <- integer(1..500_000_000),
          premium <- integer(0..20_000_000)
        ) do
      %{
        id: id,
        expiry: @now + week * 604_800,
        strike_per_token: strike,
        premium_per_token: premium
      }
    end
  end

  property "of two bids with one expiry, the one better for a seller in premium and strike comes first" do
    check all(
            bid <- open_bid(),
            more_premium <- integer(0..5_000_000),
            more_strike <- integer(0..50_000_000),
            more_premium + more_strike > 0,
            spot <- one_of([constant(nil), integer(1..500_000_000)])
          ) do
      better = %{
        bid
        | id: bid.id + 1,
          premium_per_token: bid.premium_per_token + more_premium,
          strike_per_token: bid.strike_per_token + more_strike
      }

      assert Terms.for_sellers(better, spot) < Terms.for_sellers(bid, spot)
    end
  end

  property "bids are in order of expiry, and a strike above the price never outranks a higher premium" do
    check all(
            spot <- integer(1..500_000_000),
            bid <- open_bid(),
            over <- integer(0..1_000_000_000_000),
            less <- integer(1..20_000_000)
          ) do
      at_price = %{bid | strike_per_token: spot, premium_per_token: bid.premium_per_token + less}
      far_strike = %{bid | id: bid.id + 1, strike_per_token: spot + over}
      later = %{at_price | expiry: bid.expiry + 604_800, premium_per_token: 20_000_000 + less}

      assert Terms.for_sellers(at_price, spot) < Terms.for_sellers(far_strike, spot)
      assert Terms.for_sellers(far_strike, spot) < Terms.for_sellers(later, spot)
    end
  end

  test "a listing or bid that can never change again is read once and kept" do
    over = @now - 2 * Terms.exercise_window()

    settled_listing =
      CoveredCallsChain.listing(%{seller: @wallet, expiry: over, returned: 1, exercised: @unit})

    settled_bid = CoveredCallsChain.bid(%{bidder: @wallet, expiry: over, filled: 10 * @unit})
    # Past its expiry with a refund still to take, so it can change.
    unsettled_bid = CoveredCallsChain.bid(%{bidder: @wallet, expiry: over, refund_due: 5})

    CoveredCallsChain.install(%{
      listings: [settled_listing, CoveredCallsChain.listing(%{})],
      bids: [settled_bid, unsettled_bid]
    })

    assert {:ok, %{listings: [%{id: 2}], bids: []}} = Book.read("AMZNc")

    # The chain never changes a settled record; the double does, to show which are read again.
    CoveredCallsChain.put(%{
      listings: [%{settled_listing | filled: 1}, CoveredCallsChain.listing(%{filled: 5 * @unit})],
      bids: [%{settled_bid | filled: 1}, %{unsettled_bid | refund_due: 0, amount: 0, filled: 0}],
      claimable: @unit
    })

    :ok = Book.expire("AMZNc")
    assert {:ok, %{listings: [%{id: 2, filled: refilled}]}} = Book.read("AMZNc")
    assert refilled == 5 * @unit

    assert {:ok, positions} = Positions.read("AMZNc", @wallet)
    assert [%{id: 1, filled: sold}] = positions.sold
    assert sold == 4 * @unit
    # The settled bid is as first read; the other, since stopped and refunded, is finished.
    assert [%{id: 1, filled: filled, refundable: 0}] = positions.bids
    assert filled == 10 * @unit
    # Stock from a settled listing some of which was exercised can still be claimed.
    assert [%{listing_id: 1, claimable: @unit, listing: %{id: 1}}] = positions.holdings
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

    assert {:ok, positions} = Positions.read("AMZNc", @wallet)
    assert Enum.map(positions.holdings, &{&1.listing_id, &1.listing.id}) == [{1, 1}, {2, 2}]
    assert {:ok, %{listings: [_only]}} = Book.read("AMZNc")
  end

  test "a wallet's place is asked only of listings it can have one on" do
    # Nothing was bought from either listing, so no one holds calls on them.
    CoveredCallsChain.install(%{
      listings: for(_n <- 1..2, do: CoveredCallsChain.listing(%{filled: 0})),
      held: @unit
    })

    assert {:ok, %{holdings: []}} = Positions.read("AMZNc", @wallet)
  end

  test "the shared reading carries the open bids beside the listings, read once for every visitor" do
    bids = [
      CoveredCallsChain.bid(%{}),
      CoveredCallsChain.bid(%{amount: 0, filled: 0, min_sale: 2 * @unit})
    ]

    CoveredCallsChain.install(%{bids: bids})
    {:ok, reading} = Book.read("AMZNc")

    assert [open] = reading.bids
    assert open.id == 1
    assert open.bidder == "0x3333333333333333333333333333333333333333"
    assert {open.amount, open.filled, open.min_sale} == {10 * @unit, 4 * @unit, @unit}
    assert {open.strike_per_token, open.premium_per_token} == {260_000_000, 3_000_000}
    assert open.expiry == hd(Terms.expiries(@now))

    # A bid posted after the reading waits for the next one, as a listing does.
    CoveredCallsChain.put(%{bids: bids ++ [CoveredCallsChain.bid(%{})]})
    assert {:ok, %{bids: [_one]}} = Book.read("AMZNc")
  end

  test "a wallet's positions carry its own bids with what a refund would send it now" do
    CoveredCallsChain.install(%{
      bids: [
        CoveredCallsChain.bid(%{bidder: @wallet, refund_due: 6_000_000, refundable: 6_000_000}),
        CoveredCallsChain.bid(%{}),
        CoveredCallsChain.bid(%{bidder: @wallet, refundable: 18_000_000}),
        # Stopped with nothing sold and the refund taken: finished.
        CoveredCallsChain.bid(%{bidder: @wallet, amount: 0, filled: 0})
      ]
    })

    assert {:ok, positions} = Positions.read("AMZNc", @wallet)
    assert [%{id: 1, refundable: 6_000_000}, %{id: 3, refundable: 18_000_000}] = positions.bids
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
