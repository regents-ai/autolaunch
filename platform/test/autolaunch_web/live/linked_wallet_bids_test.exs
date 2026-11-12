defmodule AutolaunchWeb.LinkedWalletBidsTest do
  @moduledoc """
  A person's bids are those of every wallet their account links, not only the
  one they signed in with: a bid placed from a second linked wallet has its
  Withdraw or Claim on the home list and the portfolio, and the card a press
  opens names the wallet it belongs to and says to switch to it.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System
  alias Autolaunch.TestSupport

  @signed_in "0x1111111111111111111111111111111111111111"
  @second "0x5555555555555555555555555555555555555555"

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

  test "its card names the bid's wallet and, from the signed-in one, says to switch",
       %{conn: conn, account: account, auction: auction, bid: bid} do
    # Pressing opens the card, as it does once launches are open.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)

    {:ok, view, _html} = conn |> signed_in(account) |> live("/")

    view
    |> element(~s(button[phx-click="open_settlement"][phx-value-id="#{auction.id}"]))
    |> render_click()

    card = "#home-settle-#{bid.id}-input"
    view |> with_target(card) |> render_hook("onchain_active_wallet", %{"address" => @signed_in})

    assert has_element?(view, "#{card}-owner-full", @second)

    assert render(element(view, card)) =~
             "This bid was placed from 0x5555..5555. Switch to that wallet in your wallet app to settle it."

    # The button stays: a press goes to the server, which says what to do.
    assert has_element?(view, ~s(#{card} [data-onchain-step="settle"]))
  end

  test "the portfolio lists it with its button", %{conn: conn, account: account, bid: bid} do
    {:ok, view, _html} = conn |> signed_in(account) |> live("/portfolio")

    assert has_element?(
             view,
             ~s(#autolaunch-bid-#{bid.id} button[phx-click="open_settlement"])
           )
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
        onchain_bid_id: "7"
      },
      actor: %System{}
    )
    |> Ash.create!()
  end
end
