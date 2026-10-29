defmodule AutolaunchWeb.BidSettlementPressTest do
  @moduledoc """
  A settlement press made before the card has read its review still reaches the
  wallet: the card prepares the review for the press and hands back its first
  step to send, as the bid form does (`AutolaunchWeb.BidComponent`).
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]
  import Phoenix.LiveViewTest

  alias Autolaunch.Actors.System
  alias Autolaunch.{LabAbi, TestAutolaunchBidSettlementChainClient}

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
    render_hook(card, "prepare_and_send", %{"form" => %{}, "step" => "settle"})

    assert_reply(view, %{send: "exit", review: %{steps: [%{step: "exit", data: data}]}})
    assert data == RegentChain.BuilderCode.append(exit_bid_data())
  end

  defp position!(%{auction: auction, wallet: wallet}) do
    {:ok, bid} =
      Autolaunch.import_bid_position(
        "lab:settle-press:#{Elixir.System.unique_integer([:positive])}",
        auction.id,
        wallet,
        "12",
        "0.00003",
        "0.00002",
        nil,
        "returnable",
        nil,
        nil,
        actor: %System{}
      )

    {:ok, bid} =
      Autolaunch.set_bid_chain_identity(
        bid,
        Autolaunch.BidFixture.auction_address(),
        Integer.to_string(@bid_id),
        actor: %System{}
      )

    bid
  end

  # A failed auction: the bid exits with its whole amount and there is nothing to claim.
  defp install do
    TestAutolaunchBidSettlementChainClient.install(%{
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
    })
  end

  defp exit_bid_data, do: LabAbi.selector("exitBid(uint256)") <> word(@bid_id)
  defp word(value), do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")
end
