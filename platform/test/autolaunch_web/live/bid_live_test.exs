defmodule AutolaunchWeb.BidLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture
  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System
  alias Autolaunch.TestAutolaunchBidChainClient, as: Chain

  @wallet "0x1111111111111111111111111111111111111111"
  @second "0x5555555555555555555555555555555555555555"
  @other "0x2222222222222222222222222222222222222222"
  @approval_hash "0x" <> String.duplicate("aa", 32)
  @bid_hash "0x" <> String.duplicate("cc", 32)
  @panel "#autolaunch-bid"

  setup %{conn: conn} do
    install()

    account =
      Accounts.register_verified!(
        "did:privy:bid-live:#{Elixir.System.unique_integer([:positive])}",
        @wallet,
        [@wallet, @second],
        actor: %System{}
      )

    auction = auction!("Bidder page auction")

    report =
      Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(
        "0x9999999999999999999999999999999999999999"
      )

    Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: %System{})

    on_exit(fn ->
      Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
    end)

    %{
      conn: init_test_session(conn, %{human_account_id: account.id}),
      auction: auction
    }
  end

  test "late A report is visible without replacing reviewed B", %{conn: conn, auction: auction} do
    view = reviewed(conn, auction)
    assert_push_event(view, "autolaunch-bid:operation", %{action_id: a})
    press = Ecto.UUID.generate()

    render_hook(element(view, @panel), "wallet_press_dispatch", %{
      action_id: a,
      press_id: press,
      step: "token_approval",
      signer: @wallet
    })

    assert_receive {_ref, {:push_event, "wallet-press:send", _}}, 5_000
    view |> element("#{@panel} button", "Start a new bid") |> render_click()
    view |> element("#{@panel} button", "Place another bid") |> render_click()
    view |> form("#autolaunch-bid-form", %{amount: "11", max_price: "4"}) |> render_change()
    view |> form("#autolaunch-bid-form") |> render_submit()
    assert_push_event(view, "autolaunch-bid:operation", %{action_id: b, terminal: false})
    refute a == b

    render_hook(element(view, @panel), "wallet_press_report", %{
      action_id: a,
      press_id: press,
      step: "token_approval",
      transaction_hash: @approval_hash
    })

    assert_push_event(view, "wallet-press:durable", %{"press_id" => ^press})
    assert_receive {_ref, {:push_event, "wallet-press:updated", _}}, 5_000
    assert has_element?(view, "[data-bid-send='#{b}']")
    assert has_element?(view, "[data-wallet-press='#{press}']", @approval_hash)
    render_hook(element(view, @panel), "wallet_press_restore", %{action_id: a})
    assert has_element?(view, "[data-bid-send='#{b}']")
  end

  test "out-of-order task deliveries merge row versions and cannot cross a replaced lease" do
    now = DateTime.utc_now()
    earlier = DateTime.add(now, -1, :second)

    row = %{
      id: Ecto.UUID.generate(),
      step: :bid,
      state: :dispatched,
      transaction_hash: nil,
      result: %{},
      evidence: %{},
      inserted_at: earlier,
      updated_at: earlier
    }

    sibling = %{row | id: Ecto.UUID.generate()}

    old = %{
      action_id: "A",
      step: :bid,
      state: :dispatched,
      terminal_at: nil,
      revision: earlier,
      attempts: [row]
    }

    current = %{
      old
      | state: :confirmed,
        terminal_at: now,
        revision: now,
        attempts: [
          %{row | state: :confirmed, transaction_hash: @bid_hash, updated_at: now},
          sibling
        ]
    }

    lease = %{lineage: "fixture-A", account_id: 1}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id: "autolaunch-bid",
        session_lease: lease,
        operation: current,
        wallet_press_history: %{"A" => current}
      }
    }

    result = %{operation: old}

    assert {:ok, updated} =
             AutolaunchWeb.BidComponent.update(
               %{wallet_press_lease: lease, wallet_press_result: {:verify, {:ok, result}}},
               socket
             )

    assert updated.assigns.operation.state == :confirmed
    assert Enum.count(updated.assigns.operation.attempts) == 2

    assert Enum.find(updated.assigns.operation.attempts, &(&1.id == row.id)).transaction_hash ==
             @bid_hash

    replacement = %{
      socket
      | assigns: %{socket.assigns | session_lease: %{lineage: "fixture-B", account_id: 2}}
    }

    assert {:ok, ^replacement} =
             AutolaunchWeb.BidComponent.update(
               %{wallet_press_lease: lease, wallet_press_result: {:verify, {:ok, result}}},
               replacement
             )
  end

  test "SIMPLE_PRODUCT_FORM: the compact form reviews an amount, a maximum price and an estimate",
       %{conn: conn, auction: auction} do
    view = mount_bidder(conn, auction)

    assert has_element?(view, "#{@panel}[phx-hook='AutolaunchBidWallet']")
    assert has_element?(view, ".bid-wallet dd", "100")
    assert has_element?(view, "#regent-buy", "Buy REGENT")
    assert has_element?(view, "#regent-chart", "View REGENT Chart")

    view
    |> form("#autolaunch-bid-form", %{amount: "12.5", max_price: "3"})
    |> render_change()

    assert render(view) =~ "about 5 tokens"

    view |> element("#{@panel} button", "Max") |> render_click()
    assert has_element?(view, "#autolaunch-bid-amount[value='100']")

    view
    |> form("#autolaunch-bid-form", %{amount: "12.5", max_price: "3"})
    |> render_submit()

    review = render(view)
    assert review =~ "12.5 REGENT"
    assert review =~ "Allow REGENT to be spent"
    assert review =~ "Allow this auction to draw REGENT"
    assert review =~ "Place the bid"
    assert has_element?(view, "#autolaunch-bid-review button", "Confirm in wallet")

    # No calldata, contract vocabulary or internal workflow state reaches the page.
    for jargon <- ["0xa52c8728", "Permit2", "calldata", "submitBid", "prevTick", "envelope"] do
      refute review =~ jargon
    end
  end

  test "ACTIVE_WALLET_IS_THE_SIGNER: an unlinked selection exposes nothing and cannot review", %{
    conn: conn,
    auction: auction
  } do
    {:ok, view, _html} = live(conn, "/auctions/#{auction.id}")
    render_async(view, 5_000)
    render_hook(element(view, @panel), "bid_active_wallet", %{"address" => @other})

    assert render(view) =~ "Switch back to a wallet on this account"
    refute has_element?(view, "#autolaunch-bid-form")

    render_hook(element(view, @panel), "bid_active_wallet", %{"address" => @wallet})
    assert has_element?(view, "#autolaunch-bid-form")
  end

  test "ACTIVE_WALLET_IS_THE_SIGNER: no Ethereum wallet is an empty state, not a refusal", %{
    conn: conn,
    auction: auction
  } do
    view = mount_bidder(conn, auction)
    assert has_element?(view, "#autolaunch-bid-form")

    render_hook(element(view, @panel), "bid_active_wallet", %{"address" => nil})

    assert render(view) =~ "Choose the wallet you want to bid from."
    refute has_element?(view, ".bid-notice")
    refute has_element?(view, "#autolaunch-bid-form")
  end

  test "ACTIVE_WALLET_IS_THE_SIGNER: switching wallets withdraws an undispatched review", %{
    conn: conn,
    auction: auction
  } do
    view = reviewed(conn, auction)
    assert has_element?(view, "#autolaunch-bid-review")

    render_hook(element(view, @panel), "bid_active_wallet", %{"address" => @second})

    assert_push_event(view, "autolaunch-bid:cleared", %{})
    refute has_element?(view, "#autolaunch-bid-review")
    assert has_element?(view, "#autolaunch-bid-form")
  end

  test "PRODUCTION_STAYS_CLOSED: the page says bidding is not open and offers no review", %{
    conn: conn,
    auction: auction
  } do
    Application.delete_env(:autolaunch, :autolaunch_bid_chain_client)
    view = mount_bidder(conn, auction)

    html = render(view)
    assert html =~ "Bidding is not open on this auction yet."
    refute has_element?(view, "#autolaunch-bid-form")
    refute html =~ "Confirm in wallet"
    assert has_element?(view, "#regent-buy", "Buy REGENT")
    assert has_element?(view, "#regent-chart", "View REGENT Chart")
  end

  test "each distinct press reaches dispatch even while a sibling receipt read waits", %{
    conn: conn,
    auction: auction
  } do
    view = reviewed(conn, auction)
    assert_push_event(view, "autolaunch-bid:operation", %{action_id: action_id})
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    dispatch = fn id ->
      render_hook(element(view, @panel), "wallet_press_dispatch", %{
        action_id: action_id,
        step: "token_approval",
        press_id: id,
        signer: @wallet
      })
    end

    dispatch.(a)
    assert_receive {_ref, {:push_event, "wallet-press:send", %{"press_id" => ^a}}}, 5_000
    owner = self()

    Chain.put(%{
      raced: fn ->
        send(owner, {:reading_receipt, self()})

        receive do
          :release -> :ok
        end
      end
    })

    render_hook(element(view, @panel), "wallet_press_report", %{
      action_id: action_id,
      press_id: a,
      step: "token_approval",
      transaction_hash: @approval_hash
    })

    assert_push_event(view, "wallet-press:durable", %{"press_id" => ^a})
    assert_receive {:reading_receipt, reader}, 5_000
    dispatch.(b)
    assert_receive {_ref, {:push_event, "wallet-press:send", %{"press_id" => ^b}}}, 5_000
    send(reader, :release)
    assert_receive {_ref, {:push_event, "wallet-press:updated", _}}, 5_000
    assert has_element?(view, "[data-wallet-press='#{a}']")
    assert has_element?(view, "[data-wallet-press='#{b}']")
  end

  test "THE_SERVER_DECIDES_TRUTH: a reported hash is verified here and never by the browser", %{
    conn: conn,
    auction: auction
  } do
    view = reviewed(conn, auction)
    assert_push_event(view, "autolaunch-bid:operation", %{action_id: action_id})

    claim(view, action_id)
    Chain.put(%{outcomes: %{token_approval: %{outcome: :confirmed}}})

    submit(view, action_id, "token_approval", @approval_hash)

    page = render(view)
    assert page =~ "Confirmed"
    assert page =~ "0xaaaaaa…aaaa"
    assert has_element?(view, ~s(#{@panel} li[data-step="permit2_approval"]), "Ready")
  end

  test "A_BOUND_HASH_IS_THE_TRUTH: a Base read that cannot answer keeps the sent transaction", %{
    conn: conn,
    auction: auction
  } do
    view = reviewed(conn, auction)
    assert_push_event(view, "autolaunch-bid:operation", %{action_id: action_id})

    claim(view, action_id)
    Chain.put(%{outcomes: %{token_approval: {:error, :chain_unavailable}}})

    submit(view, action_id, "token_approval", @approval_hash)

    page = render(view)
    assert page =~ "Sent"
    assert page =~ "0xaaaaaa…aaaa"
    assert has_element?(view, "#{@panel} button", "Check again")
    assert page =~ "Base could not be read just now."
    refute page =~ "Nothing was sent"

    # Nothing rolls back to the state before the hash bound.
    refute has_element?(view, ~s(#{@panel} li[data-step="token_approval"]), "Ready")
  end

  test "A_LOST_CALLBACK_REPLAYS: the exact durable hash is acknowledged and nothing rebinds", %{
    conn: conn,
    auction: auction
  } do
    view = reviewed(conn, auction)
    assert_push_event(view, "autolaunch-bid:operation", %{action_id: action_id})

    claim(view, action_id)
    Chain.put(%{outcomes: %{token_approval: %{outcome: :confirmed}}})
    submit(view, action_id, "token_approval", @approval_hash)

    assert_push_event(view, "autolaunch-bid:hash-durable", %{
      action_id: ^action_id,
      step: "token_approval",
      transaction_hash: @approval_hash
    })

    # A reload replays the callback it never got an answer for. The bid has
    # advanced, so the hash reaches only its own column, which already holds it.
    submit(view, action_id, "token_approval", @approval_hash)

    assert_push_event(view, "autolaunch-bid:hash-durable", %{transaction_hash: @approval_hash})
    assert has_element?(view, ~s(#{@panel} li[data-step="permit2_approval"]), "Ready")

    # A replay naming a step this bid is not on binds nowhere at all.
    submit(view, action_id, "bid", @bid_hash)

    assert render(view) =~ "not the step this bid is waiting for"
    refute render(view) =~ "0xcccccc…cccc"
  end

  test "A_REJECTION_ENDS_THE_CLAIM: nothing is resent and the browser storage is cleared", %{
    conn: conn,
    auction: auction
  } do
    view = reviewed(conn, auction)
    assert_push_event(view, "autolaunch-bid:operation", %{action_id: action_id})
    claim(view, action_id)

    render_hook(element(view, @panel), "bid_wallet_rejected", %{
      "action_id" => action_id,
      "code" => 4001
    })

    assert render(view) =~ "Not sent"
    assert_push_event(view, "autolaunch-bid:operation", %{terminal: true})
  end

  test "ONLY_A_PROVEN_MISS_SAYS_NOTHING_WAS_SENT: each reported reason gets its own copy", %{
    conn: conn,
    auction: auction
  } do
    view = reviewed(conn, auction)
    assert_push_event(view, "autolaunch-bid:operation", %{action_id: action_id})
    claim(view, action_id)

    # The wallet may already hold this transaction, so nothing here may invite a
    # retry or claim the send failed.
    failed(view, "send_unconfirmed")

    assert render(view) =~
             "Your wallet may have sent this transaction. Check your wallet activity before you start another bid."

    refute render(view) =~ "That did not go through"

    # The wallet was never reachable to be asked, which is the one reason that
    # proves nothing was sent.
    failed(view, "wallet_unavailable")

    assert render(view) =~
             "Open the wallet you are bidding from, then try again. Nothing was sent."

    failed(view, "unknown")

    page = render(view)
    assert page =~ "That did not go through. Try again in a moment."
    refute page =~ "Nothing was sent"
  end

  test "RELOAD_RECOVERS_THE_ROW: a stale browser hint restores nothing", %{
    conn: conn,
    auction: auction
  } do
    {:ok, view, _html} = live(conn, "/auctions/#{auction.id}")
    render_async(view, 5_000)
    render_hook(element(view, @panel), "bid_active_wallet", %{"address" => @wallet})
    render_hook(element(view, @panel), "restore_bid_operation", %{})

    assert_push_event(view, "autolaunch-bid:cleared", %{})
    refute has_element?(view, "#autolaunch-bid-review")
  end

  test "EXIT_CLAIM_AND_REFUND_ARE_NOT_BUILT: the page offers no position controls", %{
    conn: conn,
    auction: auction
  } do
    page = conn |> mount_bidder(auction) |> render()

    for absent <- ["Review exit", "Review claim", "Review return", "Reclaim", "Refund"] do
      refute page =~ absent
    end
  end

  defp mount_bidder(conn, auction) do
    {:ok, view, _html} = live(conn, "/auctions/#{auction.id}")
    render_async(view, 5_000)
    render_hook(element(view, @panel), "bid_active_wallet", %{"address" => @wallet})
    view
  end

  defp reviewed(conn, auction) do
    view = mount_bidder(conn, auction)

    view
    |> form("#autolaunch-bid-form", %{amount: "12.5", max_price: "3"})
    |> render_submit()

    view
  end

  defp failed(view, reason),
    do: render_hook(element(view, @panel), "bid_wallet_failed", %{"reason" => reason})

  defp claim(view, action_id),
    do: render_hook(element(view, @panel), "sign_bid_step", %{"action-id" => action_id})

  defp submit(view, action_id, step, hash) do
    render_hook(element(view, @panel), "bid_submitted", %{
      "action_id" => action_id,
      "step" => step,
      "transaction_hash" => hash
    })

    assert_receive {_ref, {:push_event, "wallet-press:updated", _}}, 5_000
    render(view)
  end
end
