defmodule AutolaunchWeb.LinkedWalletBidsTest do
  @moduledoc """
  A person's bids are those of every wallet their account links, not only the
  one they signed in with: a bid placed from a second linked wallet has its
  Withdraw or Claim on the home list and the portfolio, and the wallet that is
  open settles it, since the auction pays the wallet that placed the bid
  whoever sends. Another account's bid is never listed and cannot be settled.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}

  alias Autolaunch.{
    BidSettlementActions,
    LabAbi,
    TestAutolaunchBidSettlementChainClient,
    TestSupport
  }

  alias AutolaunchWeb.SessionAuthorityHelpers
  alias RegentChain.BuilderCode

  @signed_in "0x1111111111111111111111111111111111111111"
  @second "0x5555555555555555555555555555555555555555"
  @stranger "0x6666666666666666666666666666666666666666"
  @bid_id 7
  @q96 79_228_162_514_264_337_593_543_950_336

  setup do
    unique = Elixir.System.unique_integer([:positive])

    account =
      Accounts.register_verified!(
        "did:privy:two-wallets-#{unique}",
        @signed_in,
        [@signed_in, @second],
        actor: %System{}
      )

    auction =
      TestSupport.project_auction(
        chain_id: 8453,
        title: "Second Wallet",
        state: :failed,
        opened_at: ~U[2026-08-20 11:00:00Z]
      )

    bid = bid!(auction, @second)
    {:ok, account: account, auction: auction, bid: bid}
  end

  # A7: only the signed-in wallet's bids were read, so this bid's Withdraw
  # never appeared (money-path audit, 12 Nov 2026).
  test "the home list offers the return of a bid from a second linked wallet",
       %{conn: conn, account: account, auction: auction} do
    {:ok, view, _html} = conn |> signed_in(account) |> live("/")

    assert has_element?(
             view,
             ~s(button[phx-click="open_settlement"][phx-value-id="#{auction.id}"])
           )
  end

  # The card asked the person to switch to the bid's wallet, though the
  # auction pays that wallet whoever sends (review of A7, 12 Nov 2026).
  test "its card is prepared for the wallet that is open, and names the wallet it pays",
       %{conn: conn, account: account, auction: auction, bid: bid} do
    # Pressing opens the card, as it does once launches are open.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
    returns_whole_bid()

    {:ok, view, _html} = conn |> signed_in(account) |> live("/")

    view
    |> element(~s(button[phx-click="open_settlement"][phx-value-id="#{auction.id}"]))
    |> render_click()

    card = "#home-settle-#{bid.id}-input"
    view |> with_target(card) |> render_hook("onchain_active_wallet", %{"address" => @signed_in})
    render_async(view)

    exit_data = BuilderCode.append(exit_bid_data())

    assert_push_event(view, "onchain-steps:review", %{
      review: %{signer: @signed_in, steps: [%{step: "exit", data: ^exit_data}]}
    })

    assert render(element(view, "#{card}-paid-to")) =~ "0x5555..5555"
    assert has_element?(view, "#{card}-paid-to-full", @second)
    assert has_element?(view, ~s(#{card} [data-onchain-step="exit"]))
  end

  test "the portfolio lists it with its button", %{conn: conn, account: account, bid: bid} do
    {:ok, view, _html} = conn |> signed_in(account) |> live("/portfolio")

    assert has_element?(
             view,
             ~s(#autolaunch-bid-#{bid.id} button[phx-click="open_settlement"])
           )
  end

  # Nothing proved the account's own wallets bound the list and the settlement
  # (review of A7, 12 Nov 2026).
  test "another account's bid is never listed, and its settlement is refused",
       %{conn: conn, account: account} do
    unique = Elixir.System.unique_integer([:positive])

    Accounts.register_verified!("did:privy:stranger-#{unique}", @stranger, [@stranger],
      actor: %System{}
    )

    theirs =
      TestSupport.project_auction(
        chain_id: 8453,
        title: "Stranger",
        state: :failed,
        opened_at: ~U[2026-08-20 11:00:00Z]
      )

    stranger_bid = bid!(theirs, @stranger)
    returns_whole_bid(@stranger)

    {:ok, home, _html} = conn |> signed_in(account) |> live("/")

    refute has_element?(
             home,
             ~s(button[phx-click="open_settlement"][phx-value-id="#{theirs.id}"])
           )

    {:ok, portfolio, _html} = conn |> signed_in(account) |> live("/portfolio")
    refute has_element?(portfolio, "#autolaunch-bid-#{stranger_bid.id}")

    opts = [
      actor: %Human{human_account_id: account.id},
      context: %{session_lease: SessionAuthorityHelpers.current_lease(account.id)}
    ]

    for wallet <- [@signed_in, @second] do
      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :not_your_bid}} =
               BidSettlementActions.prepare(stranger_bid.id, wallet, opts)
    end
  end

  defp signed_in(conn, account) do
    session = signed_in_session(account.id)
    conn |> Phoenix.ConnTest.init_test_session(session) |> connects_with(session)
  end

  defp bid!(auction, owner) do
    Autolaunch.Bid
    |> Ash.Changeset.for_create(
      :project_lab,
      %{
        bid_id: "lab:second-wallet:#{Elixir.System.unique_integer([:positive])}",
        auction_id: auction.id,
        owner_address: owner,
        amount: "12",
        max_price: "0.00003",
        current_clearing_price: "0.00002",
        status: :returnable,
        auction_address: auction.auction_address,
        onchain_bid_id: Integer.to_string(@bid_id)
      },
      actor: %System{}
    )
    |> Ash.create!()
  end

  # The auction did not reach its minimum: the bid `owner` placed exits with
  # its whole amount and there is nothing to claim.
  defp returns_whole_bid(owner \\ @second) do
    TestAutolaunchBidSettlementChainClient.install(%{
      end_block: 90,
      claim_block: 95,
      currency: Autolaunch.BidFixture.regent(),
      final_clearing_price_q96: 2 * @q96,
      bid: %{
        start_block: 10,
        exited_block: 0,
        max_price_q96: 3 * @q96,
        owner: owner,
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

  defp exit_bid_data,
    do:
      LabAbi.selector("exitBid(uint256)") <>
        (@bid_id |> Integer.to_string(16) |> String.pad_leading(64, "0"))
end
