defmodule AutolaunchWeb.BidApprovalTest do
  @moduledoc """
  An approval stays on the bid panel once the chain holds it: the review built
  again after it lands keeps it, done, and the bid's button sends the same step
  the bidder would have built without it. One sent from a review the panel has
  since replaced moves it on too (onchain-buttons, rules 1 and 6).
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture
  import Phoenix.LiveViewTest

  alias Autolaunch.{BaseRpcStub, BidActions, TestAutolaunchBidChainClient}
  alias Phoenix.LiveView.AsyncResult

  @hash "0x" <> String.duplicate("a", 64)
  @permit2_hash "0x" <> String.duplicate("b", 64)

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
        inputs: first_inputs,
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

    # A press the server prepares (the page's form no longer matched its
    # review) builds the bid for the values pressed: the approval stays in it,
    # done, and the press sends the bid, not the approval the chain holds.
    render_hook(panel, "prepare_and_send", %{"form" => first_inputs, "step" => "bid"})

    assert_reply(view, %{
      send: "bid",
      review: %{steps: [^approval, %{step: "bid"}]}
    })
  end

  # The panel builds its review again as soon as an approval lands, and a
  # bidder who pressed the next approval meanwhile, and confirmed it in the
  # wallet only afterwards, reports it against the review it was sent from.
  test "an approval sent from the review the panel replaced still moves it on to the bid once it lands",
       %{conn: conn, account: account, auction: auction, wallet: wallet} do
    # The wallet has approved nothing yet: neither the auction's currency to
    # Permit2 nor Permit2's allowance for this auction.
    install()
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
        steps: [
          %{step: "token_approval"} = token_approval,
          %{step: "permit2_approval"} = permit2_approval,
          %{step: "bid"}
        ]
      }
    })

    # The currency approval lands, and a bid placed since moved the tick below
    # this bid's price, so the review built again is a new one that still asks
    # for the Permit2 approval, after the currency approval, done.
    TestAutolaunchBidChainClient.put(%{
      token_allowance: Integer.pow(2, 256) - 1,
      prev_tick_price_q96: Integer.pow(2, 96)
    })

    landed(@hash, wallet, chain_id, token_approval)

    render_hook(panel, "step_sent", %{
      "review_id" => first_id,
      "step" => "token_approval",
      "transaction_hash" => @hash
    })

    render_async(view)

    assert_push_event(view, "onchain-steps:review", %{
      review: %{
        id: second_id,
        steps: [%{step: "token_approval"}, %{step: "permit2_approval"}, %{step: "bid"}]
      }
    })

    assert second_id != first_id

    # The Permit2 approval was pressed from the first review before the second
    # one reached the page; the wallet reports it now, against the first.
    TestAutolaunchBidChainClient.put(%{
      permit2_amount: Integer.pow(2, 160) - 1,
      permit2_expiration: Integer.pow(2, 48) - 1
    })

    landed(@permit2_hash, wallet, chain_id, permit2_approval)

    render_hook(panel, "step_sent", %{
      "review_id" => first_id,
      "step" => "permit2_approval",
      "transaction_hash" => @permit2_hash
    })

    render_async(view)

    # Once it lands, the review on the page asks only for the bid.
    assert_push_event(view, "onchain-steps:review", %{
      review: %{steps: [%{step: "token_approval"}, %{step: "bid"}]}
    })

    assert has_element?(view, "#bid .token-swap__wallet-step[data-onchain-step=bid]")
    refute has_element?(view, "#bid [data-onchain-step=permit2_approval]")
  end

  # The chain holds `step`, sent from `wallet` as `hash`, and its receipt.
  defp landed(hash, wallet, chain_id, step) do
    BaseRpcStub.put(%{
      transactions: %{
        hash => %{
          "hash" => hash,
          "chainId" => "0x" <> Integer.to_string(chain_id, 16),
          "from" => wallet,
          "to" => step.to,
          "input" => step.data,
          "value" => "0x0"
        }
      },
      receipts: %{hash => BaseRpcStub.receipt(hash, "0x1c9c381", [])}
    })
  end
end
