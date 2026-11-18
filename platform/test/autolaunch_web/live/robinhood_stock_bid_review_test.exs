defmodule AutolaunchWeb.RobinhoodStockBidReviewTest do
  @moduledoc """
  The Robinhood auction page's bid review is for the wallet that sends it: the
  person's open wallet, never the auction it bids on. The page's wallet sends
  every step from the review's signer, so a review naming the auction sent
  nothing (agent Robinhood bids rehearsal on the Robinhood lab, 18 Nov 2026).

  Robinhood Chain is `Autolaunch.RobinhoodBidChain`.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1, system: 0]
  import Phoenix.LiveViewTest

  alias Autolaunch.{Accounts, RobinhoodBidChain}
  alias RegentChain.Address

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

  # The page reports Privy's active wallet as its app writes it, checksummed; the
  # review and the panel both keep the lowercase form (`RegentChain.Address`).
  test "a bid's review on the auction page is for the person's open wallet, in any letter case: the same wallet again keeps it, and another of theirs gets its own",
       %{conn: conn, account: account, wallet: wallet, opts: opts} do
    {:ok, bytes} = Address.decode("0xabcdef0123456789abcdef0123456789abcdef01")
    open = Address.checksum(bytes)
    assert open != String.downcase(open)
    {:ok, account} = Accounts.refresh_verified(account, wallet, [wallet, open], actor: system())
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Panel, session: %{"account_id" => account.id})

    panel = with_target(view, "#bid")
    render_hook(panel, "onchain_active_wallet", %{"address" => open})

    render_hook(panel, "bid_form_changed", %{
      "amount" => "12.5",
      "basis" => "price",
      "price" => "3"
    })

    render_async(view)
    assert_reviewed(view, String.downcase(open), opts)

    # The same wallet again: the review stays, neither withdrawn nor built again.
    render_hook(panel, "onchain_active_wallet", %{"address" => open})
    render_async(view)
    refute_push_event(view, "onchain-steps:review", %{})

    # Another wallet the account links: the review is replaced by one for it.
    render_hook(panel, "onchain_active_wallet", %{"address" => wallet})
    render_async(view)
    assert_reviewed(view, wallet, opts)
  end

  # The review the page was handed is `signer`'s, with the steps the bid action
  # prepares for it.
  defp assert_reviewed(view, signer, opts) do
    {:ok, prepared} =
      Autolaunch.Robinhood.StockBidActions.prepare(
        %{auction: RobinhoodBidChain.auction(), usdg_amount: "12.5", max_price: "3"},
        signer,
        opts
      )

    assert_push_event(view, "onchain-steps:review", %{review: %{signer: ^signer, steps: steps}})
    assert steps == prepared.steps
  end
end
