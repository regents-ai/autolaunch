defmodule AutolaunchWeb.RobinhoodStockBidReviewTest do
  @moduledoc """
  The Robinhood auction page's bid review is for the wallet that sends it: the
  person's open wallet, never the auction it bids on. The page's wallet sends
  every step from the review's signer, so a review naming the auction sent
  nothing (agent Robinhood bids rehearsal on the Robinhood lab, 18 Nov 2026).

  Robinhood Chain is `Autolaunch.RobinhoodBidChain`.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]
  import Phoenix.LiveViewTest

  alias Autolaunch.RobinhoodBidChain

  setup :bidder

  setup do
    RobinhoodBidChain.install()
    :ok
  end

  # The bid panel as the auction page holds it while bidding is open, for the
  # signed-in person.
  defmodule Panel do
    use Phoenix.LiveView

    alias Phoenix.LiveView.AsyncResult

    def mount(_params, %{"account_id" => account_id}, socket) do
      {:ok,
       assign(socket,
         account_id: account_id,
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account_id)
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={AutolaunchWeb.RobinhoodStockBidComponent}
        id="bid"
        page={:auction}
        auction={Autolaunch.RobinhoodBidChain.auction()}
        token_symbol="RDOG"
        ended={nil}
        stake_path={nil}
        launch={
          %{
            quote_token_symbol: "TSLA",
            quote_token_decimals: 18,
            required_currency_raised: "2",
            estimated_end_at: nil
          }
        }
        book={AsyncResult.ok(%{clearing_q96: 1, clearing: "1", price_to_beat: nil, block: 100})}
        supply={AsyncResult.ok(nil)}
        usd_prices={AsyncResult.ok(:test_network)}
        authenticated
        current_human_id={@account_id}
        session_lease={@lease}
      />
      """
    end
  end

  test "a bid's review on the auction page is for the person's open wallet",
       %{conn: conn, account: account, wallet: wallet, opts: opts} do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Panel, session: %{"account_id" => account.id})

    panel = with_target(view, "#bid")
    render_hook(panel, "onchain_active_wallet", %{"address" => wallet})

    render_hook(panel, "bid_form_changed", %{
      "amount" => "12.5",
      "basis" => "price",
      "price" => "3"
    })

    render_async(view)

    {:ok, prepared} =
      Autolaunch.Robinhood.StockBidActions.prepare(
        %{auction: RobinhoodBidChain.auction(), usdg_amount: "12.5", max_price: "3"},
        wallet,
        opts
      )

    assert_push_event(view, "onchain-steps:review", %{review: %{signer: signer, steps: steps}})
    assert signer == String.downcase(wallet)
    assert steps == prepared.steps
  end
end
