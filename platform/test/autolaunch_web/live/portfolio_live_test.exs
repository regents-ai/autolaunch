defmodule AutolaunchWeb.PortfolioLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System
  alias Autolaunch.TestSupport

  @wallet_a "0xaaaa00000000000000000000000000000000a501"
  @wallet_a_paired "0xaaaa00000000000000000000000000000000a502"
  @wallet_b "0xbbbb00000000000000000000000000000000b501"

  test "signed-out visitors see the sign-in copy and keep the account-control marker", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/portfolio")

    assert has_element?(view, "#account-control[data-account-kind=sign_in]")
    assert has_element?(view, "#autolaunch-holdings", "Your portfolio")
    assert html =~ "Sign in to view your portfolio."
    refute html =~ "Bids from your verified wallets will appear here."
  end

  test "signed-in portfolio has honest empty states", %{conn: conn} do
    account = account!("empty", @wallet_a, [@wallet_a])

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/portfolio")

    html = render(view)

    assert has_element?(view, "#account-control[data-account-kind=signed_in]")
    assert has_element?(view, "#autolaunch-holdings", "Your portfolio")
    assert html =~ "Bids from your verified wallets will appear here."
    assert html =~ "No positions are returnable."
    assert html =~ "Claimed launch tokens will appear here."
    refute has_element?(view, "#autolaunch-holdings button")
    refute html =~ "$"
  end

  test "the page shows only the signed-in user's positions, returns, and claimed tokens", %{
    conn: conn
  } do
    account_a = account!("visible-a", @wallet_a, [@wallet_a, @wallet_a_paired])
    _account_b = account!("visible-b", @wallet_b, [@wallet_b])
    return_auction = auction!("Returnable Research Launch")
    claimed_auction = auction!("Claimed Research Launch")

    claimed_token =
      TestSupport.project_token(
        auction_id: claimed_auction.id,
        name: "Claimed Research Token",
        symbol: "CRT",
        graduated_at: DateTime.utc_now()
      )

    bid!("live:returnable", return_auction.id, mixedcase(@wallet_a),
      amount: "25",
      max_price: "2.5",
      current_clearing_price: "1.75",
      estimated_tokens_if_end_now: "14",
      status: "returnable"
    )

    bid!("live:claimed", claimed_auction.id, mixedcase(@wallet_a_paired),
      amount: "40",
      status: "claimed",
      claimed_at: DateTime.utc_now()
    )

    bid!("live:other-user", return_auction.id, @wallet_b,
      amount: "999",
      status: "returnable"
    )

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account_a.id})
      |> live("/portfolio")

    html = render(view)

    assert has_element?(view, "#autolaunch-bid-live\\:returnable", "Returnable")
    assert has_element?(view, "#autolaunch-bid-live\\:claimed", "Claimed Research Launch · CRT")
    assert html =~ "Bid amount"
    assert html =~ "25"
    assert html =~ "Maximum price"
    assert html =~ "2.5"
    assert html =~ "Current price"
    assert html =~ "1.75"
    assert html =~ "Estimated tokens"
    assert html =~ "14"
    assert html =~ "This position can be returned."
    assert html =~ "No return is started from this page."

    assert has_element?(
             view,
             ~s(#autolaunch-bid-live\\:returnable a[href="/auctions/#{return_auction.id}"]),
             "View auction"
           )

    assert has_element?(view, "#autolaunch-returnable-positions", "Returnable Research Launch")
    assert html =~ "This page never opens a wallet or starts a transaction."

    assert has_element?(
             view,
             ~s(#autolaunch-held-tokens a[href="/tokens/#{claimed_token.id}"]),
             "Claimed Research Launch · CRT"
           )

    refute html =~ "Claimed Research Token"

    refute has_element?(view, "#autolaunch-bid-live\\:other-user")
    refute has_element?(view, "#autolaunch-bid-positions dd", "999")
    refute has_element?(view, "#autolaunch-returnable-positions li", "999")
    refute has_element?(view, "#autolaunch-holdings button")
    refute has_element?(view, "#autolaunch-holdings [phx-click]")
    refute html =~ "$"
  end

  test "a claimed holding keeps the one token admitted for its auction", %{conn: conn} do
    account = account!("unique-token", @wallet_a, [@wallet_a])
    auction = auction!("One Token Launch")

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        name: "One Token",
        symbol: "ONE",
        graduated_at: DateTime.utc_now()
      )

    bid!("live:one-token", auction.id, @wallet_a,
      status: "claimed",
      claimed_at: DateTime.utc_now()
    )

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/portfolio")

    html = render(view)

    assert has_element?(
             view,
             ~s(#autolaunch-held-tokens a[href="/tokens/#{token.id}"]),
             "One Token Launch · ONE"
           )

    refute html =~ "One Token · ONE"
    refute html =~ "Ambiguous Token"
    refute html =~ "AMB"
  end

  defp account!(suffix, primary, addresses) do
    Accounts.register_verified!(
      "did:privy:holdings-#{suffix}",
      primary,
      addresses,
      actor: %System{}
    )
  end

  defp auction!(title) do
    TestSupport.project_auction(title: title, state: :active, opened_at: DateTime.utc_now())
  end

  defp bid!(bid_id, auction_id, owner_address, attrs) do
    Autolaunch.import_bid_position!(
      bid_id,
      auction_id,
      owner_address,
      Keyword.get(attrs, :amount, "10"),
      Keyword.get(attrs, :max_price, "2"),
      Keyword.get(attrs, :current_clearing_price, "1"),
      Keyword.get(attrs, :estimated_tokens_if_end_now, "5"),
      Keyword.get(attrs, :status, "active"),
      Keyword.get(attrs, :exited_at),
      Keyword.get(attrs, :claimed_at),
      actor: %System{}
    )
  end

  defp mixedcase("0x" <> address), do: "0x" <> String.upcase(address)
end
