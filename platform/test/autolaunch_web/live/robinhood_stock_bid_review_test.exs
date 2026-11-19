defmodule AutolaunchWeb.RobinhoodStockBidReviewTest do
  @moduledoc """
  The Robinhood auction page's bid review is for the wallet that sends it: the
  person's open wallet, never the auction it bids on. The page's wallet sends
  every step from the review's signer, so a review naming the auction sent
  nothing (agent Robinhood bids rehearsal on the Robinhood lab, 18 Nov 2026).
  An approval sent from a review the panel has since built again moves the
  panel on once it lands.

  Robinhood Chain is `Autolaunch.RobinhoodBidChain`.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1, system: 0]
  import Phoenix.LiveViewTest

  alias Autolaunch.{Accounts, BaseRpcStub, RobinhoodBidChain}
  alias RegentChain.Address

  @approval_hash "0x" <> String.duplicate("a", 64)

  setup :bidder

  setup do
    RobinhoodBidChain.install()
    :ok
  end

  # The bid panel as the auction page holds it while bidding is open, for the
  # signed-in person, with Robinhood's clock as the page last read it, which a
  # test moves with `{:observed, clock}`.
  defmodule Panel do
    use Phoenix.LiveView

    alias Phoenix.LiveView.AsyncResult

    def mount(_params, %{"account_id" => account_id} = session, socket) do
      {:ok,
       assign(socket,
         account_id: account_id,
         observed: session["observed"],
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account_id)
       )}
    end

    def handle_info({:observed, clock}, socket), do: {:noreply, assign(socket, observed: clock)}

    # Robinhood Chain tells whoever reads it what was read; the page ignores it.
    def handle_info({:robinhood_read, _method}, socket), do: {:noreply, socket}

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
        observed={@observed}
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

  # Robinhood's clock reads 58 and the auction opens at block 60: a bid sent
  # now lands at 58 or 59 at the earliest, which the auction refuses
  # (`AuctionNotStarted`), so its button stays, disabled, saying when bidding
  # opens, and a press hands nothing out to send. Once the page reads the clock
  # at 59, the bid may land at the start, so the review is built again and the
  # bid can be sent.
  test "two clock steps before the auction starts the bid is held on its button, saying when bidding opens, and one step before it comes back",
       %{conn: conn, account: account, wallet: wallet} do
    allowed = 100 * 10 ** 6
    RobinhoodBidChain.put(%{clock: 58, start_block: 60, usdg_allowance: allowed})
    {view, panel, inputs} = filled_panel(conn, account, wallet, ["usdg_bid"])

    assert has_element?(view, "#bid-sender-blocked:not([hidden])", "Bidding opens at block 60.")

    assert has_element?(
             view,
             ~s|#bid button[disabled][aria-describedby="bid-sender-blocked"]|,
             "Place bid"
           )

    refute has_element?(view, ~s|#bid [data-onchain-step="usdg_bid"]|)

    render_hook(panel, "prepare_and_send", %{"form" => inputs})
    assert_reply(view, reply)
    assert reply == %{}

    RobinhoodBidChain.put(%{clock: 59, start_block: 60, usdg_allowance: allowed})
    send(view.pid, {:observed, 59})
    render_async(view)

    assert has_element?(
             view,
             ~s|#bid [data-onchain-step="usdg_bid"]:not([disabled])|,
             "Place bid"
           )

    refute has_element?(view, "#bid-sender-blocked:not([hidden])")
  end

  # Robinhood Chain as `RobinhoodBidChain` answers it, except that while
  # `:gated_robinhood_chain` names a process, each request first tells that
  # process and waits for its `:go`.
  defmodule GatedChain do
    def post(url, options) do
      case Application.get_env(:autolaunch, :gated_robinhood_chain) do
        nil ->
          :ok

        gate ->
          send(gate, {:gated, self()})

          receive do
            :go -> :ok
          end
      end

      RobinhoodBidChain.post(url, options)
    end
  end

  # The held review is built again at each new reading of the clock, so its
  # summary blanked on every reading until the new review came back.
  test "while a held bid is reviewed again at a new clock reading, its summary stays on the page",
       %{conn: conn, account: account, wallet: wallet} do
    RobinhoodBidChain.put(%{clock: 57, start_block: 60, usdg_allowance: 100 * 10 ** 6})
    {view, _panel, _inputs} = filled_panel(conn, account, wallet, ["usdg_bid"])
    assert has_element?(view, "#bid .bid-form__summary:not([hidden])")

    Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__.GatedChain)
    Application.put_env(:autolaunch, :gated_robinhood_chain, self())
    on_exit(fn -> Application.delete_env(:autolaunch, :gated_robinhood_chain) end)
    RobinhoodBidChain.put(%{clock: 58, start_block: 60, usdg_allowance: 100 * 10 ** 6})
    send(view.pid, {:observed, 58})

    # The new review is on its way, and the held one is still on the page.
    assert_receive {:gated, preparing}
    assert has_element?(view, "#bid .bid-form__summary:not([hidden])")
    assert has_element?(view, "#bid-sender-blocked:not([hidden])", "Bidding opens at block 60.")

    Application.delete_env(:autolaunch, :gated_robinhood_chain)
    send(preparing, :go)
    render_async(view)

    assert has_element?(view, "#bid .bid-form__summary:not([hidden])")
    assert has_element?(view, "#bid-sender-blocked:not([hidden])", "Bidding opens at block 60.")
  end

  # An approval succeeds whatever the auction's clock, so it is never held.
  test "before the auction starts its USDG approval is still sent, and only the bid is held",
       %{conn: conn, account: account, wallet: wallet} do
    RobinhoodBidChain.put(%{clock: 5, start_block: 60})
    {view, panel, inputs} = filled_panel(conn, account, wallet, ["usdg_approval", "usdg_bid"])

    assert has_element?(view, "#bid-sender-blocked:not([hidden])", "Bidding opens at block 60.")

    assert has_element?(
             view,
             ~s|#bid [data-onchain-step="usdg_approval"]:not([disabled])|,
             "Approve USDG"
           )

    render_hook(panel, "prepare_and_send", %{"form" => inputs})
    assert_reply(view, %{send: "usdg_approval"})
  end

  # The panel builds its review again once it is ten minutes old, and a person
  # who pressed Approve USDG meanwhile, and confirmed it in the wallet only
  # afterwards, reports it against the review it was sent from.
  test "an approval sent from the review the panel replaced still moves it on to the bid once it lands",
       %{conn: conn, account: account, wallet: wallet} do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Panel, session: %{"account_id" => account.id, "observed" => 50})

    panel = with_target(view, "#bid")
    render_hook(panel, "onchain_active_wallet", %{"address" => wallet})

    render_hook(panel, "bid_form_changed", %{
      "amount" => "12.5",
      "basis" => "price",
      "price" => "3"
    })

    render_async(view)

    assert_push_event(view, "onchain-steps:review", %{
      review: %{
        id: first_id,
        chain: %{chain_id: chain_id},
        steps: [%{step: "usdg_approval"} = approval, %{step: "usdg_bid"}]
      }
    })

    # The review is ten minutes old and the stock's quote has moved since, so
    # the review built again is a new one that still asks for the approval.
    RobinhoodBidChain.put(%{quote: 9 * 10 ** 20})

    Phoenix.LiveView.send_update(view.pid, AutolaunchWeb.RobinhoodStockBidComponent,
      id: "bid",
      refresh_review: first_id
    )

    render_async(view)

    assert_push_event(view, "onchain-steps:review", %{
      review: %{id: second_id, steps: [%{step: "usdg_approval"}, %{step: "usdg_bid"}]}
    })

    assert second_id != first_id

    # Approve USDG was pressed from the first review before the second one
    # reached the page; the wallet reports it now, against the first.
    RobinhoodBidChain.put(%{
      quote: 9 * 10 ** 20,
      usdg_allowance: 100 * 10 ** 6,
      transactions: %{
        @approval_hash => %{
          "hash" => @approval_hash,
          "chainId" => "0x" <> Integer.to_string(chain_id, 16),
          "from" => wallet,
          "to" => approval.to,
          "input" => approval.data,
          "value" => "0x0"
        }
      },
      receipts: %{@approval_hash => BaseRpcStub.receipt(@approval_hash, "0x64", [])}
    })

    render_hook(panel, "step_sent", %{
      "review_id" => first_id,
      "step" => "usdg_approval",
      "transaction_hash" => @approval_hash
    })

    render_async(view)

    # Once it lands, the review on the page asks only for the bid.
    assert_push_event(view, "onchain-steps:review", %{review: %{steps: [%{step: "usdg_bid"}]}})
    assert has_element?(view, ~s|#bid [data-onchain-step="usdg_bid"]:not([disabled])|, "Place bid")
    refute has_element?(view, ~s|#bid [data-onchain-step="usdg_approval"]|)
  end

  # From its end block on, by its clock, the auction refuses a bid
  # (`AuctionIsOver`), and the clock never runs back.
  test "once Robinhood's clock reaches the end block the bid is held on its button: bidding has ended",
       %{conn: conn, account: account, wallet: wallet} do
    RobinhoodBidChain.put(%{clock: 90, end_block: 90, usdg_allowance: 100 * 10 ** 6})
    {view, _panel, _inputs} = filled_panel(conn, account, wallet, ["usdg_bid"])

    assert has_element?(view, "#bid-sender-blocked:not([hidden])", "Bidding has ended.")
    assert has_element?(view, ~s|#bid button[disabled]|, "Place bid")
    refute has_element?(view, ~s|#bid [data-onchain-step="usdg_bid"]|)
  end

  # The panel for the person's wallet with a 12.5 USDG bid at most 3 per token
  # typed, once its review with `steps` reached the page, and that review's
  # inputs, as a press sends them.
  defp filled_panel(conn, account, wallet, steps) do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Panel, session: %{"account_id" => account.id, "observed" => 5})

    panel = with_target(view, "#bid")
    render_hook(panel, "onchain_active_wallet", %{"address" => wallet})

    render_hook(panel, "bid_form_changed", %{
      "amount" => "12.5",
      "basis" => "price",
      "price" => "3"
    })

    render_async(view)
    assert_push_event(view, "onchain-steps:review", %{review: %{steps: built, inputs: inputs}})
    assert Enum.map(built, & &1.step) == steps
    {view, panel, inputs}
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
