defmodule AutolaunchWeb.RobinhoodStockBidComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.RobinhoodStockBidComponent
  alias Phoenix.LiveView.AsyncResult

  @clearing 1_000

  # The auction counts as graduated as soon as its raise reaches the minimum,
  # mid-auction too, so a bid has won only once bidding has also ended.
  defp render_bids(clock) do
    render_component(RobinhoodStockBidComponent,
      id: "bid",
      auction: "0x" <> String.duplicate("22", 20),
      book: AsyncResult.ok(%{clearing_q96: @clearing, price_to_beat: nil}),
      supply: AsyncResult.ok(nil),
      authenticated: true,
      wallet: "0x" <> String.duplicate("11", 20),
      current_human_id: nil,
      session_lease: nil,
      usd_prices: AsyncResult.ok(:test_network),
      reading: %{
        clock: clock,
        window: %{"start_block" => 100, "end_block" => 200},
        graduated?: true,
        currency_raised: "1",
        stock: %{"symbol" => "TSLA"},
        bids: [bid(1, @clearing + 1), bid(2, @clearing - 1)]
      }
    )
  end

  defp bid(id, max_price),
    do: %{
      "bid_id" => to_string(id),
      "exited_block" => "0",
      "max_price_q96" => to_string(max_price),
      "stock_committed_units" => "1"
    }

  test "a graduated auction still taking bids shows each bid's live standing" do
    html = render_bids(150)

    assert html =~ "Buying"
    refute html =~ "Won"
  end

  test "once bidding has ended with the minimum reached, bids read as won or returnable" do
    html = render_bids(200)

    assert html =~ "Won"
    assert html =~ "Outbid: return it to get the rest back"
    refute html =~ "Buying"
  end
end
