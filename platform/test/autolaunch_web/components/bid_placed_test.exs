defmodule AutolaunchWeb.BidPlacedTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AutolaunchWeb.Components.BidPlaced

  @placed [
    id: "placed",
    target: nil,
    token_symbol: "AAPLc",
    chain: :base,
    auction_path: "/auctions/aaplc",
    auction_url: "https://autolaunch.sh/auctions/aaplc",
    share_image: "https://autolaunch.sh/share/aaplc.png"
  ]

  # A placed bid once linked to the auction from the auction itself, and to the
  # portfolio from the portfolio's own dialog: each page leaves out its own link.
  test "a placed bid links on to the pages it is not on" do
    elsewhere = render_component(&BidPlaced.bid_placed/1, @placed)
    on_auction = render_component(&BidPlaced.bid_placed/1, [page: :auction] ++ @placed)
    on_portfolio = render_component(&BidPlaced.bid_placed/1, [page: :portfolio] ++ @placed)

    assert elsewhere =~ ~s(href="/auctions/aaplc")
    assert elsewhere =~ ~s(href="/portfolio")
    refute on_auction =~ ~s(href="/auctions/aaplc")
    assert on_auction =~ ~s(href="/portfolio")
    assert on_portfolio =~ ~s(href="/auctions/aaplc")
    refute on_portfolio =~ ~s(href="/portfolio")
  end
end
