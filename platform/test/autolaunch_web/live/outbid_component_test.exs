defmodule AutolaunchWeb.OutbidComponentTest do
  @moduledoc """
  "Your bids" on an auction offers what the bidder can do next with a bid
  still in the auction: Add while it is buying, Raise once it is outbid. A bid
  that has left the auction shows its status and offers neither.
  """
  use AutolaunchWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Autolaunch.{Auction, Bid, BidActions}
  alias Phoenix.LiveView.AsyncResult

  @auction %Auction{
    id: "00000000-0000-4000-8000-000000000001",
    quote_token_symbol: "REGENT",
    quote_token_decimals: 18
  }

  test "an active bid above the price offers Add" do
    html = render_position(:active, below_max())

    assert html =~ "Add to this bid"
    refute html =~ "Raise my bid"
  end

  test "an active bid the price has passed offers Raise" do
    html = render_position(:active, above_max())

    assert html =~ "Raise my bid to keep buying"
    refute html =~ "Add to this bid"
  end

  test "a bid that has left the auction shows its status and offers neither" do
    html = render_position(:returnable, below_max())

    assert html =~ "Returnable"
    refute html =~ "Add to this bid"
    refute html =~ "Raise my bid"
  end

  defp render_position(status, clearing_q96) do
    render_component(AutolaunchWeb.OutbidComponent,
      id: "position",
      position: %Bid{
        id: Ash.UUID.generate(),
        bid_id: "lab:position:1",
        status: status,
        onchain_bid_id: "1",
        amount: "10",
        max_price: "0.001",
        auction: @auction
      },
      book: %AsyncResult{
        ok?: true,
        result: %{clearing_q96: clearing_q96, clearing: "0", block: 1}
      },
      authenticated: false,
      current_human_id: nil,
      session_lease: nil
    )
  end

  defp max_q96 do
    {:ok, q96} = BidActions.price_q96("0.001", 18)
    q96
  end

  defp below_max, do: max_q96() - 1
  defp above_max, do: max_q96() + 1
end
