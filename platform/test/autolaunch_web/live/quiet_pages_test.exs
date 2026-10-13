defmodule AutolaunchWeb.QuietPagesTest do
  @moduledoc """
  Open pages are told only what changed, and a page told too little shows an
  old figure with no error to notice. Each case holds one side of that: what
  must still be announced, and what must stay quiet.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Ecto.Query

  alias Autolaunch.Actors.System

  alias Autolaunch.{
    Auction,
    BaseRpcStub,
    BidActivity,
    MarketReadings,
    MarketTicker,
    Repo,
    TestSupport
  }

  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  test "the lists hear a bid-activity pass only when it changed an event or a figure" do
    auction = TestSupport.project_auction(state: :active)
    id = auction.id
    Autolaunch.Listings.subscribe()

    # The scanner saving its place moves nothing a list shows.
    auction = refresh_activity(auction, %{activity_next_block: 10, events_changed: false})
    refute_received {:autolaunch_listings_changed, ^id}

    auction =
      refresh_activity(auction, %{
        activity_next_block: 11,
        bid_volume: Decimal.new(5),
        events_changed: false
      })

    assert_received {:autolaunch_listings_changed, ^id}

    refresh_activity(auction, %{activity_next_block: 12, events_changed: true})
    assert_received {:autolaunch_listings_changed, ^id}
  end

  test "an auction page reads its row again for a new reading of its own auction, and for no other's",
       %{conn: conn} do
    # No feed runs under ExUnit, so the readings below are this case's own. The
    # page's price read is refused at once; its saved row is what the case watches.
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, BaseRpcStub.Timeout)
    on_exit(fn -> Application.delete_env(:autolaunch, :autolaunch_lab_http_client) end)

    stored = TestSupport.project_auction(chain_id: 8453, symbol: "QUIET", title: "First words")
    other = TestSupport.project_auction(chain_id: 8453, symbol: "OTHER")
    on_exit(fn -> MarketReadings.forget([stored.auction_address, other.auction_address]) end)

    {:ok, auction} = Paths.find_auction("QUIET", String.slice(stored.auction_address, -5, 5))
    {:ok, view, _html} = live(conn, Paths.auction(auction))
    assert render_async(view) =~ "First words"

    Repo.update_all(from(a in Auction, where: a.id == ^auction.id), set: [title: "Second words"])

    # The feed stores another auction's new reading and moves its clock. The
    # page takes the clock and reads nothing.
    MarketReadings.store("base", block(2), [reading(other, 2)])
    html = render_async(view)
    assert html =~ "First words"
    refute html =~ "Second words"

    MarketReadings.store("base", block(3), [reading(stored, 3)])
    assert render_async(view) =~ "Second words"
  end

  test "the price ticker sends a list only when it differs from the last one" do
    # The ticker's list may be another case's; settle it on this database first.
    reread_ticker()
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, MarketTicker.topic())

    reread_ticker()
    refute_received {:market_ticker, _entries}

    auction = TestSupport.project_auction(state: :active)
    record_bid(auction)
    reread_ticker()
    assert_received {:market_ticker, [{:bid, %{bid_id: "1"}}]}

    reread_ticker()
    refute_received {:market_ticker, _entries}

    Repo.delete_all(BidActivity)
    reread_ticker()
    assert_received {:market_ticker, []}
  end

  defp refresh_activity(auction, changes),
    do: Ash.update!(auction, changes, action: :refresh_activity, actor: %System{})

  defp block(number),
    do: %{
      number: number,
      hash: "0x" <> String.pad_leading(Integer.to_string(number, 16), 64, "0")
    }

  # One auction's figures as a market feed stores them, raised to `raised`.
  defp reading(auction, raised) do
    %{
      auction_id: auction.id,
      auction_address: String.downcase(auction.auction_address),
      block_number: raised,
      start_block: 1,
      end_block: 1_000,
      claim_block: 1_010,
      currency_raised: Integer.to_string(raised),
      remaining_supply: "0"
    }
  end

  # The call returns once the ticker has handled the reread.
  defp reread_ticker do
    send(MarketTicker, :load)
    :sys.get_state(MarketTicker)
  end

  defp record_bid(auction) do
    Ash.create!(
      BidActivity,
      %{
        auction_id: auction.id,
        bid_id: "1",
        bidder: "0x1111111111111111111111111111111111111111",
        transaction_hash: "0x" <> String.duplicate("ab", 32),
        block_hash: "0x" <> String.duplicate("cd", 32),
        block_number: 10,
        log_index: 0,
        clock_block: 10,
        occurred_at: DateTime.utc_now(),
        amount: Decimal.new(5),
        display_amount: Decimal.new(5),
        display_symbol: "REGENT",
        max_price: Decimal.new(1)
      },
      action: :record,
      actor: %System{}
    )
  end
end
