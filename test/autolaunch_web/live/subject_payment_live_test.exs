defmodule AutolaunchWeb.SubjectPaymentLiveTest do
  @moduledoc """
  The subject wallet card on the subject page: what each visitor is offered, what
  a review actually says, and what the browser is allowed to make it do.
  """

  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.SubjectWalletFixture, as: Fixture
  alias Autolaunch.TestAutolaunchSubjectWalletChainClient, as: ChainClient

  @card "#autolaunch-subject-wallet"
  @wallet Fixture.wallet()
  @approval_hash "0x" <> String.duplicate("a1", 32)
  @action_hash "0x" <> String.duplicate("b2", 32)
  @unit Integer.pow(10, 18)

  # Every removed control of the superseded subject-payment lane.
  @removed_ids [
    "#subject-payment-wallet",
    "#subject-payment-review",
    "#subject-payment-link-create-form",
    "#subject-payment-link-canonical-form",
    "#subject-payment-link-state-form",
    "#subject-ingress-sweep-form",
    "#subject-stake-form",
    "#subject-unstake-form",
    "#subject-claim-usdc-form"
  ]

  setup do
    Fixture.install()
    Fixture.actor()
  end

  describe "SIGNED_OUT_EXPOSES_NO_SENDABLE_ACTION" do
    test "an anonymous visitor is offered sign-in and no wallet control at all", %{
      conn: conn,
      subject: subject
    } do
      {:ok, view, _html} = live(conn, path(subject))
      render_async(view, 5_000)

      assert has_element?(view, @card, "Sign in to continue")
      refute has_element?(view, "#{@card} [data-subject-wallet-send]")
      refute has_element?(view, "#{@card} form")

      # No private fact of any wallet reaches an anonymous visitor. The subject's
      # own published addresses are page content and stay exactly as they were.
      for private <- ["Staked", "Wallet", "Review"] do
        refute has_element?(view, @card, private)
      end
    end

    test "a not-found subject mounts no wallet card whatsoever", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/subjects/nope-42")
      render_async(view, 5_000)

      assert has_element?(view, "#autolaunch-subject-detail", "Subject not found")
      refute has_element?(view, @card)
    end

    test "the superseded lane leaves no control and no copy behind", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      {:ok, view, html} = signed_in(conn, account, subject)

      for id <- @removed_ids, do: refute(has_element?(view, id))

      for copy <- [
            "Payment links, revenue, and subject staking",
            "AutolaunchSubjectPaymentWallet",
            "Retry approval verification",
            "Retry confirmation"
          ] do
        refute html =~ copy
      end
    end
  end

  describe "ONE_ACTIVE_PRIVY_WALLET_ON_SCREEN" do
    test "no selected wallet is the ordinary empty state, reading nothing", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      {:ok, view, _html} = signed_in(conn, account, subject)

      assert has_element?(view, "#{@card} [data-subject-wallet-connect]")

      # A Solana or disconnected selection reports no address at all.
      html = active_wallet(view, nil)
      refute html =~ "Staked"
      assert has_element?(view, "#{@card} [data-subject-wallet-connect]")
    end

    test "the selected wallet's own balances and stake appear", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      {:ok, view, _html} = signed_in(conn, account, subject)
      html = active_wallet(view, @wallet)

      assert html =~ "900"
      assert html =~ "Staked"
      assert html =~ "400"
      assert has_element?(view, "#{@card}-form")
    end

    test "a wallet this account does not hold sees no private state and no control", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      {:ok, view, _html} = signed_in(conn, account, subject)
      html = active_wallet(view, "0x9999999999999999999999999999999999999999")

      assert text(html) =~ "Switch back to a wallet on this account to continue."
      refute html =~ "Staked"
      refute has_element?(view, "#{@card} [data-subject-wallet-send]")
    end

    test "a subject with no revenue split says so instead of offering an action", %{
      conn: conn,
      account: account
    } do
      subject = Fixture.subject!("subject:wallet:nosplit", splitter_address: nil)
      {:ok, view, _html} = signed_in(conn, account, subject)
      html = active_wallet(view, @wallet)

      assert text(html) =~ "This subject is not sharing revenue yet."
      refute has_element?(view, "#{@card}-form")
    end
  end

  describe "THE_REVIEW_SAYS_WHAT_WILL_HAPPEN" do
    test "a stake review shows the amount, the wallet, and its two steps", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)

      # The form says what a stake does before anything is reviewed, and the
      # review says it again, with no countdown, timer or readiness check.
      timing =
        "Your stake counts straight away. You can take it back out from the next block onwards."

      assert text(render(view)) =~ timing

      html = review(view, :stake, %{"amount" => "10"})

      assert text(html) =~ timing
      refute text(html) =~ "at any time"

      assert html =~ "Stake"
      assert html =~ "10 SUBJECT"
      assert html =~ "Base"
      assert has_element?(view, "#{@card}-review")

      assert has_element?(
               view,
               ~s(#{@card} li[data-step="approval"]),
               "Allow SUBJECT to be spent"
             )

      assert has_element?(view, ~s(#{@card} li[data-step="action"]), "Stake")
      assert has_element?(view, "#{@card} [data-subject-wallet-send]")

      # No calldata, selector, or internal state reaches the customer.
      refute html =~ "0xa694fc3a"
      refute html =~ "prepared"
      refute html =~ "calldata"
    end

    # The fixture stakes 1_000 of the 100-billion SUBJECT supply, so the staker
    # allocation really is zero and the review says so in exact amounts rather
    # than as a share, and only for the moment it was reviewed.
    test "a payment review states the exact amount each part of the split receives", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      html = review(view, :pay, %{"asset" => "usdc", "amount" => "5"})

      assert text(html) =~
               "Of this 5 USDC, 0.1 USDC goes to the protocol. As things stand right now, the remaining 4.9 USDC divides into 0 USDC for everyone staking SUBJECT on this subject and 4.9 USDC for its treasury. If staking changes before this goes through, those last two amounts change with it."

      # No rounded share is ever offered in place of the amounts.
      refute text(html) =~ "98%"
      refute text(html) =~ "2% of this"
    end

    test "a tenth of the supply staked earns exactly a tenth of the net", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      ChainClient.install(
        Fixture.fixture(total_staked: 10_000_000_000 * @unit, staked_of: 400 * @unit)
      )

      view = ready(conn, account, subject)
      html = review(view, :pay, %{"asset" => "usdc", "amount" => "5"})

      assert text(html) =~
               "As things stand right now, the remaining 4.9 USDC divides into 0.49 USDC for everyone staking SUBJECT on this subject and 4.41 USDC for its treasury."
    end

    test "a sweep review says plainly that the signer receives nothing", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      html = review(view, :sweep, %{"asset" => "usdc"})

      assert text(html) =~ "Nothing is sent to your wallet"
      assert text(html) =~ "another sweep before yours can make this fail"
      assert html =~ "7"
    end

    test "a refused action explains itself in plain language and prepares nothing", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      html = review(view, :stake, %{"amount" => "9000"})

      assert text(html) =~ "That is more than this wallet holds."
      refute has_element?(view, "#{@card}-review")
    end

    test "Max fills the amount this action can actually use", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)

      select(view, :unstake)

      html =
        view |> element(~s(#{@card} button[phx-click="fill_subject_amount"])) |> render_click()

      assert html =~ ~s(value="400")
    end
  end

  describe "THE_BROWSER_REPORTS_A_HASH_AND_STOPS" do
    test "a claimed step is handed the reviewed bytes exactly once", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})

      action_id = action_id(view)
      render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})

      assert_push_event(view, "autolaunch-subject-wallet:send", %{
        action_id: ^action_id,
        step: "action"
      })

      # A claimed step stays offered so a repeat press can reach the wallet.
      assert has_element?(view, "#{@card} [data-subject-wallet-send]")
    end

    test "a reported hash becomes a Basescan link and its outcome comes from the server", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)

      render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})
      ChainClient.put(%{outcomes: %{action: %{outcome: :confirmed}}})

      html =
        render_hook(element(view, @card), "subject_wallet_submitted", %{
          "action_id" => action_id,
          "step" => "action",
          "transaction_hash" => @action_hash
        })

      assert html =~ "https://basescan.org/tx/#{@action_hash}"
      assert text(html) =~ "Confirmed on Base."
      assert_push_event(view, "autolaunch-subject-wallet:hash-durable", %{step: "action"})
    end

    test "an approval settles and the action it enables becomes sendable", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :stake, %{"amount" => "10"})
      action_id = action_id(view)

      render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})
      ChainClient.put(%{outcomes: %{approval: %{outcome: :confirmed}}})

      html =
        render_hook(element(view, @card), "subject_wallet_submitted", %{
          "action_id" => action_id,
          "step" => "approval",
          "transaction_hash" => @approval_hash
        })

      assert html =~ "https://basescan.org/tx/#{@approval_hash}"
      assert has_element?(view, "#{@card} [data-subject-wallet-send]")
      assert has_element?(view, ~s(#{@card} li[data-step="approval"]), "Confirmed")
    end

    test "an explicit wallet rejection ends the action and says nothing was sent", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)

      render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})

      html =
        render_hook(element(view, @card), "subject_wallet_rejected", %{
          "action_id" => action_id,
          "code" => 4001
        })

      assert text(html) =~ "Your wallet declined this. Nothing was sent."
      refute has_element?(view, "#{@card} [data-subject-wallet-send]")
    end

    test "a send that never began returns the same review to sendable", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)

      render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})
      assert has_element?(view, "#{@card} [data-subject-wallet-send]")

      render_hook(element(view, @card), "subject_wallet_dispatch_not_started", %{
        "action_id" => action_id
      })

      assert has_element?(view, "#{@card} [data-subject-wallet-send]")
    end

    test "a reload restores the open action from the owning account's own row", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)

      reopened = ready(conn, account, subject)
      html = render_hook(element(reopened, @card), "restore_subject_wallet_operation", %{})

      assert html =~ "Unstake"
      assert action_id(reopened) == action_id
    end

    test "a verified revert is terminal and never offers another send", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)

      render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})
      ChainClient.put(%{outcomes: %{action: %{outcome: :reverted}}})

      html =
        render_hook(element(view, @card), "subject_wallet_submitted", %{
          "action_id" => action_id,
          "step" => "action",
          "transaction_hash" => @action_hash
        })

      assert text(html) =~ "This transaction reverted on Base. Nothing moved."
      refute has_element?(view, "#{@card} [data-subject-wallet-send]")
    end

    test "a browser-reported failure never claims more than it knows", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)

      html =
        render_hook(element(view, @card), "subject_wallet_failed", %{
          "reason" => "send_unconfirmed"
        })

      assert text(html) =~ "Your wallet may have sent this transaction."

      html =
        render_hook(element(view, @card), "subject_wallet_failed", %{
          "reason" => "wallet_unavailable"
        })

      assert html =~ "Nothing was sent."
    end
  end

  describe "A_CONFIRMED_ACTION_SHOWS_WHAT_ITS_OWN_EVENT_PROVED" do
    test "a confirmed claim shows the amount its event recorded, not the estimate", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)

      html =
        confirmed(view, :claim, %{"asset" => "usdc"}, %{
          outcome: :confirmed,
          result: %{"claimed" => %{Fixture.usdc() => "9500000"}}
        })

      assert html =~ "9.5 USDC"
      refute html =~ "12 USDC"
      assert text(html) =~ "Confirmed on Base."
    end

    test "a confirmed claim that collected nothing shows a truthful zero", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)

      html =
        confirmed(view, :claim, %{"asset" => "usdc"}, %{
          outcome: :confirmed,
          result: %{"claimed" => %{}}
        })

      assert html =~ "0 USDC"
      refute html =~ "12 USDC"
      assert text(html) =~ "There was nothing available to claim."
    end

    test "a confirmed sweep shows the gross its routing event reported", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)

      html =
        confirmed(view, :sweep, %{"asset" => "usdc"}, %{
          outcome: :confirmed,
          result: %{"gross" => "6500000", "note" => Fixture.note_word(Fixture.receiver())}
        })

      assert html =~ "6.5 USDC"
      refute html =~ "7 USDC"
      assert text(html) =~ "Confirmed on Base."
    end

    test "a stored result carrying no whole amount keeps the reviewed one", %{conn: conn} do
      for claimed <- ["not a map", %{Fixture.usdc() => "twelve"}, %{Fixture.usdc() => 12}, %{}] do
        Fixture.install()
        context = Fixture.actor()
        view = ready(conn, context[:account], context[:subject])

        html =
          confirmed(view, :claim, %{"asset" => "usdc"}, %{
            outcome: :confirmed,
            result: %{"claimed" => claimed}
          })

        # An empty map is the one truthful zero; every other unusable shape
        # leaves the reviewed estimate exactly where it was, and none of them
        # takes the card down.
        assert text(html) =~ "Confirmed on Base."
        assert html =~ if(claimed == %{}, do: "0 USDC", else: "12 USDC")
      end
    end

    test "a row that settled as anything but confirmed keeps the reviewed estimate", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      html = confirmed(view, :claim, %{"asset" => "usdc"}, %{outcome: :reverted})

      assert html =~ "12 USDC"
      assert text(html) =~ "This transaction reverted on Base. Nothing moved."
    end
  end

  describe "RECOVERY_IS_SCOPED_TO_THE_CURRENT_LEASE" do
    test "a fresh browser on the same account recovers its own open action", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      {_signed_in, view} = mounted(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)

      {_other_browser, reopened} = mounted(build_conn(), account, subject)
      html = render_hook(element(reopened, @card), "restore_subject_wallet_operation", %{})

      assert html =~ "Unstake"
      assert action_id(reopened) == action_id
    end

    test "a revoked lease recovers no field of the open action at all", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      {_signed_in, view} = mounted(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)

      # A second browser on this account mounts and has adopted no wallet yet.
      browser = init_test_session(build_conn(), %{human_account_id: account.id})
      {:ok, reopened, _html} = live(browser, path(subject))
      render_async(reopened, 5_000)
      assert SessionAuthority.revoke(claim_of(browser))

      html = render_hook(element(reopened, @card), "restore_subject_wallet_operation", %{})

      assert text(html) =~ "Sign in again to continue."
      refute html =~ action_id
      refute html =~ "Unstake"
      refute has_element?(reopened, "#{@card}-review")
      refute has_element?(reopened, "#{@card} [data-subject-wallet-send]")
    end

    test "another account's browser recovers nothing of this account's action", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      {_signed_in, view} = mounted(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)

      stranger = Fixture.actor()[:account]
      {_browser, theirs} = mounted(build_conn(), stranger, subject)
      html = render_hook(element(theirs, @card), "restore_subject_wallet_operation", %{})

      refute html =~ action_id
      refute has_element?(theirs, "#{@card}-review")
    end
  end

  describe "CRAFTED_BROWSER_VALUES_ARE_MAPPED_OR_IGNORED" do
    test "an action kind outside the seven selects nothing and makes no atom", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      select(view, :unstake)
      crafted = "crafted_kind_#{Elixir.System.unique_integer([:positive])}"

      render_hook(element(view, @card), "select_subject_action", %{"kind" => crafted})

      assert has_element?(view, ~s(#{@card}-action-unstake[aria-pressed="true"]))
      assert_raise ArgumentError, fn -> String.to_existing_atom(crafted) end
    end

    test "a step outside approval and action binds nothing and makes no atom", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)
      render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})

      crafted = "crafted_step_#{Elixir.System.unique_integer([:positive])}"

      render_hook(element(view, @card), "subject_wallet_submitted", %{
        "action_id" => action_id,
        "step" => crafted,
        "transaction_hash" => @action_hash
      })

      assert_raise ArgumentError, fn -> String.to_existing_atom(crafted) end
      refute render(view) =~ @action_hash
    end

    test "an asset outside the three fills no amount and prepares nothing", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      select(view, :pay)

      render_hook(element(view, @card), "subject_form_changed", %{"asset" => "dai"})

      assert view
             |> element(~s(#{@card} button[phx-click="fill_subject_amount"]))
             |> render_click() =~ ~s(value="")

      # The select itself offers only the three, so a crafted asset can only
      # arrive on a hand-made submit, where preparation names the refusal.
      html =
        render_hook(element(view, @card), "review_subject_action", %{
          "asset" => "dai",
          "amount" => "1"
        })

      assert text(html) =~ "Choose SUBJECT, USDC, or REGENT."
      refute has_element?(view, "#{@card}-review")
    end

    test "a reported code that is not the wallet's own rejection ends nothing", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)
      render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})

      for code <- [4002, "4001", 0, nil] do
        html =
          render_hook(element(view, @card), "subject_wallet_rejected", %{
            "action_id" => action_id,
            "code" => code
          })

        refute text(html) =~ "Your wallet declined this."
      end

      # The wallet's own rejection still ends exactly this claimed step.
      html =
        render_hook(element(view, @card), "subject_wallet_rejected", %{
          "action_id" => action_id,
          "code" => 4001
        })

      assert text(html) =~ "Your wallet declined this. Nothing was sent."
    end
  end

  describe "SWITCHING_WALLETS_CANCELS_ONLY_AN_UNDISPATCHED_REVIEW" do
    test "an undispatched review is withdrawn when the wallet changes", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      assert has_element?(view, "#{@card}-review")

      active_wallet(view, "0x9999999999999999999999999999999999999999")
      refute has_element?(view, "#{@card}-review")
    end

    test "a claimed action stays bound to the wallet it was reviewed for", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      view = ready(conn, account, subject)
      review(view, :unstake, %{"amount" => "10"})
      action_id = action_id(view)

      render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})

      active_wallet(view, "0x9999999999999999999999999999999999999999")

      # The wallet is not held by this account, so nothing private shows, and the
      # claimed action was not withdrawn behind the customer's back.
      assert {:ok, %{operation: open}} =
               Autolaunch.open_subject_wallet_operation(
                 subject.subject_id,
                 actor: %Autolaunch.Actors.Human{human_account_id: account.id},
                 context: %{
                   session_lease: %{lineage: lineage(conn, account), account_id: account.id}
                 }
               )

      assert open.state == :dispatched
      assert open.signer == @wallet
    end
  end

  # Helpers

  defp path(subject), do: "/subjects/#{subject.subject_id}"

  defp signed_in(conn, account, subject) do
    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live(path(subject))

    html = render_async(view, 5_000)
    {:ok, view, html}
  end

  defp ready(conn, account, subject) do
    {_signed_in, view} = mounted(conn, account, subject)
    view
  end

  # The same card, together with the connection whose lease it mounted under, so
  # a test can revoke exactly that lease afterwards.
  defp mounted(conn, account, subject) do
    signed_in = init_test_session(conn, %{human_account_id: account.id})
    {:ok, view, _html} = live(signed_in, path(subject))
    render_async(view, 5_000)
    active_wallet(view, @wallet)
    {signed_in, view}
  end

  # One reviewed action driven all the way to whatever its own event settles it
  # as. Neither a claim nor a sweep needs an approval, so each is a single step.
  defp confirmed(view, kind, params, outcome) do
    review(view, kind, params)
    action_id = action_id(view)
    render_hook(element(view, @card), "sign_subject_wallet_step", %{"action-id" => action_id})
    ChainClient.put(%{outcomes: %{action: outcome}})

    render_hook(element(view, @card), "subject_wallet_submitted", %{
      "action_id" => action_id,
      "step" => "action",
      "transaction_hash" => unique_hash()
    })
  end

  # Every bound hash is unique across every operation, so a test that settles
  # more than one action reports a different one each time.
  defp unique_hash do
    hex = [:positive] |> Elixir.System.unique_integer() |> Integer.to_string(16)
    "0x" <> String.pad_leading(hex, 64, "0")
  end

  defp active_wallet(view, address),
    do: render_hook(element(view, @card), "subject_active_wallet", %{"address" => address})

  defp select(view, kind),
    do: view |> element("#{@card}-action-#{kind}") |> render_click()

  defp review(view, kind, params) do
    select(view, kind)
    view |> form("#{@card}-form", params) |> render_submit()
  end

  # The open action's identity, taken from whichever control the card is
  # currently showing for it.
  defp action_id(view) do
    html = render(view)

    [action_id] =
      Regex.run(~r/data-subject-wallet-send="([^"]+)"/, html, capture: :all_but_first) ||
        Regex.run(~r/phx-value-action-id="([^"]+)"/, html, capture: :all_but_first)

    action_id
  end

  # HEEx wraps long copy across source lines, so customer sentences are compared
  # against the rendered text with its whitespace collapsed.
  defp text(html), do: String.replace(html, ~r/\s+/, " ")

  defp claim_of(conn), do: conn |> get_session() |> SessionAuthority.claim()

  defp lineage(conn, account) do
    conn
    |> init_test_session(%{human_account_id: account.id})
    |> get_session("session_lineage")
  end
end
