defmodule AutolaunchWeb.MarketTickerLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # MARKET_TICKER_BEHIND_MENU: the bar along the bottom of every page is one of the
  # parts the phone navigation menu makes inert while it is open. The bar draws only
  # while there are bids or trades to show, so the mark has to be on its own markup.
  test "MARKET_TICKER_BEHIND_MENU: the bottom bar is marked as part of the page behind the phone menu" do
    auction = %{token_symbol: "SAND", path_tail: "abcd", image: nil}

    trade = %{
      side: :buy,
      currency_amount: Decimal.new("12.4"),
      currency_symbol: "USDC",
      token: %{auction: auction}
    }

    html =
      render_component(&AutolaunchWeb.MarketTickerLive.render/1, %{
        entries: [{:trade, trade}],
        paused: false,
        rates: %{ok?: false}
      })

    assert html =~ ~r/<aside[^>]*market-ticker[^>]*data-shell-behind-menu/s
  end
end
