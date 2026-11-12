defmodule AutolaunchWeb.BidSettlementPressTest do
  @moduledoc """
  A settlement press made before the card has read its review still reaches the
  wallet: the card prepares the review for the press and hands back its first
  step to send, as the bid form does (`AutolaunchWeb.BidComponent`). A step
  that did not go through is prepared again from the auction as it is then.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]
  import Phoenix.LiveViewTest

  alias Autolaunch.Actors.System
  alias Autolaunch.{BaseRpcStub, LabAbi, TestAutolaunchBidSettlementChainClient}
  alias RegentChain.BuilderCode

  @bid_id 7
  @q96 79_228_162_514_264_337_593_543_950_336

  setup :bidder

  # The card as a page holds it, for the signed-in owner of the bid.
  defmodule Card do
    use Phoenix.LiveView

    def mount(_params, %{"bid_id" => bid_id, "account_id" => account_id}, socket) do
      actor = %Autolaunch.Actors.Human{human_account_id: account_id}
      {:ok, position} = Autolaunch.get_my_bid_position(bid_id, actor: actor)

      {:ok,
       assign(socket,
         position: position,
         account_id: account_id,
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account_id)
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={AutolaunchWeb.BidSettlementComponent}
        id="card"
        position={@position}
        authenticated
        current_human_id={@account_id}
        session_lease={@lease}
      />
      """
    end
  end

  # SETTLE_PRESS_BEFORE_REVIEW_SENDS: the card's button names the action before
  # its review arrives, and a press then sent nothing (found by the agent
  # journeys, 28 Oct 2026).
  test "SETTLE_PRESS_BEFORE_REVIEW_SENDS: a settlement press with no review on the card is prepared and sent",
       %{conn: conn} = context do
    {view, card} = card(conn, context)
    render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "settle"})

    assert_reply(view, %{send: "exit", review: %{steps: [%{step: "exit", data: data}]}})
    assert data == BuilderCode.append(exit_bid_data())
  end

  # A page that connected again can report a step sent from a review this
  # server never built; the card follows no review for it and carries on.
  test "a sent step the card holds no review for leaves the next press working",
       %{conn: conn} = context do
    {view, card} = card(conn, context)

    render_hook(card, "step_sent", %{
      "review_id" => "a-review-from-before",
      "step" => "exit",
      "transaction_hash" => "0x" <> String.duplicate("ab", 32)
    })

    render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "settle"})

    assert_reply(view, %{send: "exit", review: %{steps: [%{step: "exit", data: data}]}})
    assert data == BuilderCode.append(exit_bid_data())
  end

  # A return that reverted was sent again unchanged by the next press, and
  # never left the card while the auction had moved on (money-path audit A5).
  test "a return that did not go through is prepared again from the auction as it is now",
       %{conn: conn} = context do
    {view, card} = card(conn, context)
    render_async(view)
    exit_data = BuilderCode.append(exit_bid_data())

    assert_push_event(view, "onchain-steps:review", %{
      review: %{id: first_id, steps: [%{step: "exit", data: ^exit_data} = step]} = review
    })

    # The auction now wants the partly filled exit, with its hints.
    partial = LabAbi.selector("exitPartiallyFilledBid(uint256,uint64,uint64)") <> word(@bid_id)
    install(exit: %{signature: "exitPartiallyFilledBid(uint256,uint64,uint64)", data: partial})
    reverted(card, context.wallet, review, step)
    settle_reads(view)

    assert render(view) =~
             "That did not go through, so nothing came back. Only the network fee was spent. This review now uses the latest figures: press again to send it."

    partial_data = BuilderCode.append(partial)

    assert_push_event(view, "onchain-steps:review", %{
      review: %{id: second_id, steps: [%{step: "exit", data: ^partial_data}]}
    })

    assert second_id != first_id
  end

  test "a return that did not go through after the bid was returned another way gives the auction's answer",
       %{conn: conn} = context do
    {view, card} = card(conn, context)
    render_async(view)

    assert_push_event(view, "onchain-steps:review", %{review: %{steps: [step]} = review})

    # Anyone may return a bid to its owner; the auction now has it returned.
    install(exit: {:refused, :already_exited})
    reverted(card, context.wallet, review, step)
    html = settle_reads(view)

    assert html =~
             "That did not go through, so nothing came back. Only the network fee was spent."

    assert html =~ "This bid has no tokens to claim."
    assert_push_event(view, "onchain-steps:review", %{review: nil})
  end

  # The receipt read finds the step reverted and starts the auction read; the
  # first wait covers the one, the second the other.
  defp settle_reads(view) do
    render_async(view)
    render_async(view)
  end

  # The step is sent from `review`, and Base reads it back as reverted.
  defp reverted(card, wallet, review, step) do
    hash = "0x" <> String.duplicate("c4", 32)

    BaseRpcStub.install(:autolaunch_lab_http_client, fn _call, _state -> "0x" end)

    BaseRpcStub.put(%{
      transactions: %{
        hash => %{
          "hash" => hash,
          "chainId" => "0x" <> Integer.to_string(review.chain.chain_id, 16),
          "from" => wallet,
          "to" => step.to,
          "input" => step.data,
          "value" => "0x0"
        }
      },
      receipts: %{hash => BaseRpcStub.receipt(hash, "0x1c9c381", [], "0x0")}
    })

    render_hook(card, "step_sent", %{
      "review_id" => review.id,
      "step" => step.step,
      "transaction_hash" => hash
    })
  end

  # The card of a failed auction's bid, opened by its signed-in owner with
  # their wallet active.
  defp card(conn, context) do
    Autolaunch.TestSupport.project_auction(
      address: Autolaunch.BidFixture.auction_address(),
      title: context.auction.title,
      featured: false,
      state: :failed,
      opened_at: ~U[2026-08-20 11:00:00Z]
    )

    position = position!(context)
    install()
    session = signed_in_session(context.account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Card,
        session: %{"bid_id" => position.bid_id, "account_id" => context.account.id}
      )

    card = with_target(view, "#card")
    render_hook(card, "onchain_active_wallet", %{"address" => context.wallet})
    {view, card}
  end

  defp position!(%{auction: auction, wallet: wallet}) do
    Autolaunch.Bid
    |> Ash.Changeset.for_create(
      :project_lab,
      %{
        bid_id: "lab:settle-press:#{Elixir.System.unique_integer([:positive])}",
        auction_id: auction.id,
        owner_address: wallet,
        amount: "12",
        max_price: "0.00003",
        current_clearing_price: "0.00002",
        status: :returnable,
        auction_address: Autolaunch.BidFixture.auction_address(),
        onchain_bid_id: Integer.to_string(@bid_id)
      },
      actor: %System{}
    )
    |> Ash.create!()
  end

  # A failed auction: the bid exits with its whole amount and there is nothing
  # to claim, unless `changes` say the auction answers otherwise now.
  defp install(changes \\ []) do
    failed_auction()
    |> Map.merge(Map.new(changes), fn
      :exit, %{} = exit, %{} = change -> Map.merge(exit, change)
      _key, _before, change -> change
    end)
    |> TestAutolaunchBidSettlementChainClient.install()
  end

  defp failed_auction do
    %{
      end_block: 90,
      claim_block: 95,
      currency: Autolaunch.BidFixture.regent(),
      final_clearing_price_q96: 2 * @q96,
      bid: %{
        start_block: 10,
        exited_block: 0,
        max_price_q96: 3 * @q96,
        owner: Autolaunch.BidFixture.wallet(),
        amount: 12 * 10 ** 18,
        tokens_filled: 0
      },
      graduated?: false,
      exit: %{
        signature: "exitBid(uint256)",
        data: exit_bid_data(),
        hints: nil,
        tokens_filled: 0,
        currency_refunded: 12 * 10 ** 18
      },
      claim: {:refused, :nothing_to_claim}
    }
  end

  defp exit_bid_data, do: LabAbi.selector("exitBid(uint256)") <> word(@bid_id)
  defp word(value), do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")
end
