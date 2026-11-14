defmodule AutolaunchWeb.NearFundingComponentTest do
  @moduledoc """
  Fund with NEAR on a USDC bid: shown only while Base reads the wallet short of
  the bid, it funds exactly the shortfall to the account's own wallet, and once
  the USDC arrives the bid panel reads Base again. The 1Click service is
  `Autolaunch.TestNearIntents`.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture
  import Phoenix.LiveViewTest

  alias Autolaunch.{
    BaseRpcStub,
    Funding,
    NearFunding,
    TestAutolaunchBidChainClient,
    TestNearIntents
  }

  alias Phoenix.LiveView.AsyncResult

  @near_tx "7mQZ4dJpPq8yW1vQ3sXk2aB9cD4eF5gH6iJ7kL8mN9oP"
  @base_tx "0x" <> String.duplicate("c", 64)

  setup :bidder

  setup %{auction: auction} do
    auction = Ash.Seed.update!(auction, %{kind: :stocks})
    # Starting a funding queues its status job; under ExUnit no job runs.
    start_supervised!({Oban, Application.fetch_env!(:autolaunch, Oban)})
    TestNearIntents.install()
    BaseRpcStub.install(:autolaunch_lab_http_client, fn _call, _state -> "0x" end)
    {:ok, auction: auction}
  end

  # The bid panel as the auction page holds it, with `amount` USDC typed.
  defmodule Panel do
    use Phoenix.LiveView

    def mount(_params, %{"auction" => auction, "account_id" => id, "amount" => amount}, socket) do
      {:ok,
       assign(socket,
         auction: auction,
         account_id: id,
         amount: amount,
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(id)
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={AutolaunchWeb.BidComponent}
        id="bid"
        auction={@auction}
        book={AsyncResult.ok(%{clearing_q96: 0, clearing: "0", price_to_beat: nil, block: 30_000_000})}
        preset_amount={@amount}
        preset_limit="3"
        authenticated
        current_human_id={@account_id}
        session_lease={@lease}
      />
      """
    end
  end

  defp panel(conn, account, auction, wallet, amount) do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(Panel,
        session: %{"auction" => auction, "account_id" => account.id, "amount" => amount}
      )

    render_hook(with_target(view, "#bid"), "onchain_active_wallet", %{"address" => wallet})
    # The balance read, then the quote it may start.
    render_async(view)
    render_async(view)
    view
  end

  # The funding started from the panel, and the swap then read as arrived.
  defp funded_and_arrived(view, auction, actor) do
    view |> element("#bid-near-form") |> render_submit(%{"refund_to" => "sean.near"})
    {:ok, [funding]} = Funding.near_fundings_for(auction.id, actor: actor)

    # The USDC lands on Base, and the status job reads the swap as done.
    TestAutolaunchBidChainClient.put(%{usdc_balance: 60_000_000})

    TestNearIntents.put(%{
      status: %{state: :success, origin_tx: @near_tx, destination_tx: @base_tx}
    })

    {:ok, _funding} = Funding.refresh_near_funding(funding, actor: system())

    eventually(fn -> has_element?(view, "#bid-near [aria-label=Receipt]") end)
    render_async(view)
  end

  test "a wallet holding the bid's USDC sees no NEAR funding",
       %{conn: conn, account: account, auction: auction, wallet: wallet} do
    install(usdc_balance: 50_000_000)
    view = panel(conn, account, auction, wallet, "50")

    assert has_element?(view, "#bid-near[hidden]")
    refute has_element?(view, "#bid-near-form")
    assert TestNearIntents.state().asked == []
  end

  test "a short wallet is quoted exactly its shortfall, delivered to its own wallet",
       %{conn: conn, account: account, auction: auction, wallet: wallet} do
    install(usdc_balance: 50_000_000)
    view = panel(conn, account, auction, wallet, "60.5")

    assert has_element?(view, "#bid-near:not([hidden]) #bid-near-form")

    assert [%{usdc_amount: 10_500_000, recipient: ^wallet, dry: true}] =
             TestNearIntents.state().asked

    # The fixture's 1.6513… NEAR, rounded up so it is never short.
    assert render(view) =~ "About 1.652 NEAR, around 24 seconds"
  end

  test "Fund with NEAR records the funding for the account's wallet and shows where to send",
       %{conn: conn, account: account, auction: auction, wallet: wallet, actor: actor} do
    install(usdc_balance: 50_000_000)
    view = panel(conn, account, auction, wallet, "60")

    # A recipient sent with the press is not one the funding takes.
    view
    |> element("#bid-near-form")
    |> render_submit(%{
      "refund_to" => "sean.near",
      "recipient" => "0x" <> String.duplicate("de", 20)
    })

    assert [%{dry: false, recipient: ^wallet, refund_to: "sean.near"} | _dry] =
             TestNearIntents.state().asked

    assert {:ok, [%NearFunding{} = funding]} =
             Funding.near_fundings_for(auction.id, actor: actor)

    assert %{recipient: ^wallet, usdc_amount: 10_000_000, state: :pending_deposit} = funding
    assert has_element?(view, "#bid-near-deposit", TestNearIntents.deposit_address())
    refute has_element?(view, "#bid-near-form")

    # After a reload the open funding is shown again.
    reloaded = panel(conn, account, auction, wallet, "60")
    assert has_element?(reloaded, "#bid-near-deposit", TestNearIntents.deposit_address())
  end

  test "a NEAR account that is not one is refused before anything is recorded",
       %{conn: conn, account: account, auction: auction, wallet: wallet, actor: actor} do
    install(usdc_balance: 50_000_000)
    view = panel(conn, account, auction, wallet, "60")

    view |> element("#bid-near-form") |> render_submit(%{"refund_to" => "Not An Account!"})

    assert {:ok, []} = Funding.near_fundings_for(auction.id, actor: actor)
    assert has_element?(view, "#bid-near .bid-notice:not([hidden])")
    assert has_element?(view, "#bid-near-form")
  end

  test "an arrival shows the receipt and the bid panel reads Base again",
       %{conn: conn, account: account, auction: auction, wallet: wallet, actor: actor} do
    install(usdc_balance: 50_000_000)
    view = panel(conn, account, auction, wallet, "60")
    funded_and_arrived(view, auction, actor)

    assert has_element?(view, ~s|#bid-near a[href="https://nearblocks.io/txns/#{@near_tx}"]|)
    assert has_element?(view, ~s|#bid-near a[href="https://basescan.org/tx/#{@base_tx}"]|)
    # The wallet now holds the bid's USDC, so nothing more is asked for.
    refute has_element?(view, "#bid-near-form")
    assert has_element?(view, "#bid .bid-box__balance", "60")
    # The wallet holds no ETH on Base (the double's default), which is said.
    assert has_element?(view, "#bid-near [data-near-fee]")
  end

  test "a wallet holding ETH on Base is not told it lacks the network fee",
       %{conn: conn, account: account, auction: auction, wallet: wallet, actor: actor} do
    install(usdc_balance: 50_000_000)
    BaseRpcStub.put(%{eth_balance: "0x2386f26fc10000"})
    view = panel(conn, account, auction, wallet, "60")
    funded_and_arrived(view, auction, actor)

    refute has_element?(view, "#bid-near [data-near-fee]")
  end

  # The listener hands a broadcast to the page from its own process.
  defp eventually(check, tries \\ 50) do
    cond do
      check.() ->
        :ok

      tries == 0 ->
        flunk("the panel did not change")

      true ->
        Process.sleep(20)
        eventually(check, tries - 1)
    end
  end
end
