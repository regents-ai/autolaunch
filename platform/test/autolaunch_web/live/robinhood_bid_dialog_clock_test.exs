defmodule AutolaunchWeb.RobinhoodBidDialogClockTest do
  @moduledoc """
  Every page with a Robinhood bid dialog hands it Robinhood's clock as the site
  last read it and each new reading, so a bid held because the auction has not
  started comes back as soon as it can land, with nothing typed or changed in
  the wallet. The bid's own page and the portfolio are two such pages.

  Robinhood Chain is `Autolaunch.RobinhoodBidChain`; Robinhood's clock as the
  site read it is the `"robinhood"` chain head (`Autolaunch.ChainHead`).
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]
  import Phoenix.LiveViewTest

  alias Autolaunch.{ChainHead, RobinhoodBidChain, SharedReading, TestSupport}

  @allowed 100 * 10 ** 6

  setup :bidder

  setup do
    # Past the prelaunch gate, which ignores a press until the site opens.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
    RobinhoodBidChain.install()
    on_exit(fn -> SharedReading.delete(ChainHead.key("robinhood")) end)

    listing =
      TestSupport.project_auction(
        chain_id: RobinhoodBidChain.chain_id(),
        kind: :stocks,
        address: RobinhoodBidChain.auction(),
        title: "Robinhood bid auction",
        symbol: "RDOG",
        state: :active
      )

    {:ok, listing: listing}
  end

  test "the bid page's dialog holds a bid two clock steps before the start, and brings it back once the site reads the clock one step before",
       %{conn: conn, account: account, wallet: wallet, listing: listing} do
    clock(58)
    {:ok, view, _html} = conn |> signed_in(account) |> live(bid_page())
    render_async(view)
    render_click(view, "open_early", %{})

    held_then_back(view, "#bid-early-#{listing.id}-input", wallet)
  end

  test "the portfolio's dialog holds a bid two clock steps before the start, and brings it back once the site reads the clock one step before",
       %{conn: conn, account: account, wallet: wallet, listing: listing} do
    clock(58)
    {:ok, view, _html} = conn |> signed_in(account) |> live("/portfolio")
    render_async(view)
    render_click(view, "open_robinhood", %{"id" => listing.id, "mode" => "bid"})

    held_then_back(view, "#portfolio-robinhood-bid-#{listing.id}-input", wallet)
  end

  # The auction opens at block 60. With the clock at 58 the dialog's bid is
  # held; the site then reads 59, and the dialog's bid can be sent.
  defp held_then_back(view, panel_id, wallet) do
    panel = with_target(view, panel_id)
    render_hook(panel, "onchain_active_wallet", %{"address" => wallet})

    render_hook(panel, "bid_form_changed", %{
      "amount" => "12.5",
      "basis" => "price",
      "price" => "3"
    })

    render_async(view)

    assert has_element?(
             view,
             "#{panel_id}-sender-blocked:not([hidden])",
             "Bidding opens at block 60."
           )

    refute has_element?(view, ~s|#{panel_id} [data-onchain-step="usdg_bid"]|)

    clock(59)
    render_async(view)

    assert has_element?(
             view,
             ~s|#{panel_id} [data-onchain-step="usdg_bid"]:not([disabled])|,
             "Place bid"
           )

    refute has_element?(view, "#{panel_id}-sender-blocked:not([hidden])")
  end

  # Robinhood's clock at `clock`, on the chain and as the site last read it.
  defp clock(clock) do
    RobinhoodBidChain.put(clock: clock, start_block: 60, usdg_allowance: @allowed)
    :ok = SharedReading.put(ChainHead.key("robinhood"), clock)
  end

  defp bid_page, do: "/portfolio/bids/#{RobinhoodBidChain.auction()}:7"

  defp signed_in(conn, account) do
    session = signed_in_session(account.id)
    conn |> Phoenix.ConnTest.init_test_session(session) |> connects_with(session)
  end
end
