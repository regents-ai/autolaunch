defmodule AutolaunchWeb.BidApprovalTest do
  @moduledoc """
  An approval stays on the bid panel once the chain holds it: the review built
  again after it lands keeps it, done, and the bid's button sends the same step
  the bidder would have built without it (onchain-buttons, rules 1 and 6).
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture
  import Phoenix.LiveViewTest

  alias Autolaunch.{BaseRpcStub, BidActions, TestAutolaunchBidChainClient}
  alias Phoenix.LiveView.AsyncResult

  @hash "0x" <> String.duplicate("a", 64)

  setup :bidder

  setup %{auction: auction} do
    report =
      Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(
        "0x9999999999999999999999999999999999999999"
      )

    Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: system())
    :ok
  end

  # The bid panel as the auction page holds it, for the signed-in bidder.
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

  test "a confirmed approval stays on the panel, done and pressable, and the bid sends the same step",
       %{conn: conn, account: account, auction: auction, wallet: wallet, opts: opts} do
    # The wallet still needs to approve the auction's currency to Permit2; its
    # Permit2 allowance for this auction already holds.
    install(permit2_amount: Integer.pow(2, 160) - 1, permit2_expiration: Integer.pow(2, 48) - 1)
    BaseRpcStub.install(:autolaunch_lab_http_client, fn _call, _state -> "0x" end)

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

    assert_push_event(view, "onchain-steps:review", %{
      review: %{
        id: first_id,
        chain: %{chain_id: chain_id},
        steps: [%{step: "token_approval"} = approval, %{step: "bid"} = bid]
      }
    })

    # The approval lands, and the chain now holds the allowance.
    TestAutolaunchBidChainClient.put(%{token_allowance: Integer.pow(2, 256) - 1})

    BaseRpcStub.put(%{
      transactions: %{
        @hash => %{
          "hash" => @hash,
          "chainId" => "0x" <> Integer.to_string(chain_id, 16),
          "from" => wallet,
          "to" => approval.to,
          "input" => approval.data,
          "value" => "0x0"
        }
      },
      receipts: %{@hash => BaseRpcStub.receipt(@hash, "0x1c9c381", [])}
    })

    render_hook(panel, "step_sent", %{
      "review_id" => first_id,
      "step" => "token_approval",
      "transaction_hash" => @hash
    })

    render_async(view)

    # The review built again holds the same approval, first, and the same bid:
    # its id, taken from its steps, is the first review's, so the page keeps
    # the review its button sends from.
    refute_push_event(view, "onchain-steps:review", %{})
    render_async(view)

    assert render(view) =~ "approved. Now place your bid."

    assert has_element?(
             view,
             "#bid .token-swap__approval[data-onchain-step=token_approval][data-state=done]:not([disabled]):not([hidden])"
           )

    assert has_element?(view, "#bid .token-swap__wallet-step[data-onchain-step=bid]")

    # That bid is the step the bidder builds with the allowance on the chain,
    # which needs no approval.
    assert {:ok, %{steps: [^bid]}} =
             BidActions.prepare(
               %{auction_id: auction.id, amount: "1", max_price: "3"},
               wallet,
               opts
             )
  end
end
