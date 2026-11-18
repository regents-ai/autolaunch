defmodule AutolaunchWeb.BidLastBlockTest do
  @moduledoc """
  A Base auction refuses a bid from its end block on (`AuctionIsOver`), and a
  step sent at the latest block lands in the next one at the earliest. So when
  the review on the bid panel was read one block before the end, its bid is
  certain to be refused: the button stays, disabled, saying bidding has ended,
  and a press that builds such a review sends nothing, as the agent's bid is
  refused `bidding_ended` at that block. An approval is never held
  (onchain-buttons, rule 11).
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture
  import Phoenix.LiveViewTest

  alias Autolaunch.BaseRpcStub
  alias Phoenix.LiveView.AsyncResult

  # The latest block the fixture reads is 30_000_000. With these, the chain
  # already holds both approvals, so the review is the bid alone.
  @approved [
    token_allowance: Integer.pow(2, 256) - 1,
    permit2_amount: Integer.pow(2, 160) - 1,
    permit2_expiration: Integer.pow(2, 48) - 1
  ]

  setup :bidder

  setup %{auction: auction} do
    report =
      Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(
        "0x9999999999999999999999999999999999999999"
      )

    Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: system())
    BaseRpcStub.install(:autolaunch_lab_http_client, fn _call, _state -> "0x" end)
    :ok
  end

  # The bid panel as the auction page holds it while its form is shown, for
  # the signed-in bidder.
  defmodule Panel do
    use Phoenix.LiveView

    def mount(_params, %{"auction" => auction, "account_id" => account_id}, socket) do
      {:ok,
       assign(socket,
         auction: auction,
         account_id: account_id,
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account_id)
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={AutolaunchWeb.BidComponent}
        id="bid"
        auction={@auction}
        book={AsyncResult.ok(%{clearing_q96: 0, clearing: "0", price_to_beat: nil, block: 30_000_000})}
        preset_amount="1"
        preset_limit="3"
        authenticated
        current_human_id={@account_id}
        session_lease={@lease}
      />
      """
    end
  end

  test "one block before the end the bid is held on its button, saying bidding has ended, and a press sends nothing",
       %{conn: conn, account: account, auction: auction, wallet: wallet} do
    install(@approved ++ [end_block: 30_000_001])
    {view, panel, inputs} = reviewed_panel(conn, account, auction, wallet, ["bid"])

    assert has_element?(view, "#bid-sender-blocked:not([hidden])", "Bidding has ended.")

    assert has_element?(
             view,
             ~s|#bid .token-swap__wallet-step[disabled][aria-describedby="bid-sender-blocked"]|,
             "Place bid"
           )

    refute has_element?(view, ~s|#bid [data-onchain-step="bid"]|)

    render_hook(panel, "prepare_and_send", %{"form" => inputs})
    assert_reply(view, reply)
    assert reply == %{}
  end

  test "two blocks before the end the bid can still be sent",
       %{conn: conn, account: account, auction: auction, wallet: wallet} do
    install(@approved ++ [end_block: 30_000_002])
    {view, panel, inputs} = reviewed_panel(conn, account, auction, wallet, ["bid"])

    refute has_element?(view, "#bid-sender-blocked:not([hidden])")
    assert has_element?(view, ~s|#bid [data-onchain-step="bid"]:not([disabled])|, "Place bid")

    render_hook(panel, "prepare_and_send", %{"form" => inputs})
    assert_reply(view, %{send: "bid"})
  end

  # An approval succeeds whatever the block, so only the bid after it is held.
  test "one block before the end an approval is still sent, and only the bid is held",
       %{conn: conn, account: account, auction: auction, wallet: wallet} do
    install(end_block: 30_000_001)

    {view, panel, inputs} =
      reviewed_panel(conn, account, auction, wallet, ["token_approval", "permit2_approval", "bid"])

    assert has_element?(view, "#bid-sender-blocked:not([hidden])", "Bidding has ended.")

    assert has_element?(
             view,
             ~s|#bid [data-onchain-step="token_approval"]:not([disabled])|
           )

    render_hook(panel, "prepare_and_send", %{"form" => inputs})
    assert_reply(view, %{send: "token_approval"})
  end

  # The panel for the bidder's wallet with a bid of 1 at most 3 per token, once
  # its review with `steps` reached the page, and that review's inputs, as a
  # press sends them.
  defp reviewed_panel(conn, account, auction, wallet, steps) do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Panel,
        session: %{"auction" => auction, "account_id" => account.id}
      )

    panel = with_target(view, "#bid")
    render_hook(panel, "onchain_active_wallet", %{"address" => wallet})
    render_async(view)

    assert_push_event(view, "onchain-steps:review", %{review: %{inputs: inputs, steps: built}})
    assert Enum.map(built, & &1.step) == steps

    {view, panel, inputs}
  end
end
