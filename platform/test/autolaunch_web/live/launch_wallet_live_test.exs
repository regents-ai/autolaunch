defmodule AutolaunchWeb.LaunchWalletLiveTest do
  @moduledoc """
  The launch card on each saved draft: what each visitor is offered, what a
  review actually says, and what the browser is allowed to make it do.
  """

  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.LaunchFixture, as: Fixture
  alias Autolaunch.TestAutolaunchLaunchChainClient, as: ChainClient
  alias Autolaunch.TestAutolaunchTreasuryChainClient, as: TreasuryClient

  @wallet Fixture.wallet()
  @other_wallet "0x9999999999999999999999999999999999999999"
  @approval_hash "0x" <> String.duplicate("a1", 32)
  @launch_hash "0x" <> String.duplicate("b2", 32)
  @eoa "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  @eoa_acknowledgement "This auction will be owned by my EOA private key, and significant harm and token value will happen if it is lost or compromised. I was warned to create a Gnosis Safe or 0xSplits smart account as the owner, and I realize auction bidders and token owners will see that it is EOA-owned and more risky. I accept these problems, and wish to continue with EOA ownership of the token."

  @unit Integer.pow(10, 18)
  @fee 1_000_000 * @unit

  # Every governance, receiver and construction control C4 deliberately has no
  # surface for. None of them may ever appear on this page.
  @absent_copy [
    "Set launch fee",
    "Pause launches",
    "Unpause",
    "Custom receiver",
    "Payment receiver",
    "Bind hook",
    "Initialize distribution",
    "Migrate",
    "ERC-8004",
    "Salt",
    "Start block"
  ]

  setup do
    Fixture.install()
    context = Fixture.actor()
    TreasuryClient.seed_verified!(Fixture.treasury())

    on_exit(fn ->
      Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
    end)

    context
  end

  test "STORED_TREASURY_PROOF_WAITS_FOR_A_FRESH_INTERACTION_BEFORE_VERIFIED", context do
    view = mounted(context)

    assert has_element?(
             view,
             ~s(#{card(context)} [data-treasury-verification-state="awaiting-current-chain-confirmation"]),
             "Awaiting current chain confirmation"
           )

    refute has_element?(
             view,
             ~s(#{card(context)} [data-treasury-verification-state="verified"])
           )

    view
    |> element(~s(#{card(context)} form[phx-submit="verify_treasury"]))
    |> render_submit(%{
      "usdc" => "0x" <> String.duplicate("11", 32),
      "regent" => "0x" <> String.duplicate("22", 32),
      "outbound" => "0x" <> String.duplicate("33", 32)
    })

    assert has_element?(
             view,
             ~s(#{card(context)} [data-treasury-verification-state="verified"]),
             "Verified 2-of-3 Safe"
           )
  end

  describe "SIGNED_OUT_EXPOSES_NO_SENDABLE_ACTION" do
    test "a signed-in founder with no wallet selected is offered connect, never a send",
         context do
      view = mounted(context)

      assert has_element?(view, card(context), "Choose the wallet you want to launch from.")
      refute has_element?(view, "#{card(context)} [data-launch-wallet-send]")
      refute has_element?(view, "#{card(context)} button[phx-click=\"review_launch\"]")
    end

    test "a wallet this account does not hold is refused and reads nothing", context do
      view = mounted(context)
      active_wallet(view, card(context), @other_wallet)

      assert has_element?(
               view,
               card(context),
               "Switch back to a wallet on this account to continue."
             )

      refute has_element?(view, "#{card(context)} button[phx-click=\"review_launch\"]")
    end
  end

  describe "ONE_REVIEW_SAYS_EVERYTHING_A_FOUNDER_NEEDS" do
    test "exact EOA acknowledgement and blank evidence reach high-risk review", context do
      draft =
        Autolaunch.autosave_launch_treasury!(
          context[:draft],
          %{
            "treasury" => @eoa,
            "treasury_path" => "eoa",
            "eoa_acknowledgement" => @eoa_acknowledgement
          },
          actor: context[:actor]
        )

      TreasuryClient.install(
        runtime_code: "0x",
        runtime_identity: "0x" <> String.duplicate("00", 32),
        admitted_safe?: false,
        owners: [],
        threshold: nil
      )

      selector = "#autolaunch-launch-wallet-#{draft.id}"
      view = mounted(context)
      active_wallet(view, selector, @wallet)

      html =
        view
        |> element(~s(#{selector} form[phx-submit="verify_treasury"]))
        |> render_submit(%{"usdc" => "", "regent" => "", "outbound" => ""})

      assert html =~ "Unverified"

      html =
        view
        |> element(~s(#{selector} button[phx-click="review_launch"]))
        |> render_click()

      assert html =~ "Review this launch"
      assert html =~ "Single-key EOA"
      assert has_element?(view, "#{selector} .launch-wallet-review")
    end

    test "the review names the token, raise, fee, treasury, wallet, network and count",
         context do
      view = reviewed(context)
      html = render(view)

      assert html =~ "Open Research · OPEN"
      assert html =~ "1000.5 REGENT"
      assert html =~ "1000000 REGENT"
      assert html =~ "Base"
      assert html =~ "Two transactions"
      assert html =~ "0x1111…1111"
      assert has_element?(view, "#{card(context)} .launch-wallet-review > dl", Fixture.treasury())
    end

    test "the fixed terms are plain English and never promise an exact start block", context do
      view = reviewed(context)
      html = render(view)

      assert has_element?(view, "#{card(context)} .launch-wallet-terms", "10% auction")
      assert has_element?(view, "#{card(context)} .launch-wallet-terms", "5% pool reserve")

      assert has_element?(
               view,
               "#{card(context)} .launch-wallet-terms",
               "85% escrow until settlement"
             )

      assert has_element?(view, "#{card(context)} .launch-wallet-terms", "0.30%")
      assert has_element?(view, "#{card(context)} details:not([open])", "fixed block delays")

      # No exact future start block is ever inferred for the customer.
      refute html =~ "30001800"
      refute html =~ "starts at block"
    end

    test "every technical value lives behind the one disclosure", context do
      view = reviewed(context)
      details = render(element(view, "#{card(context)} details"))

      # Raw addresses, the exact target, Q96 values, block counts, the reviewed
      # block and the digest of the exact bytes are all here and nowhere else.
      assert details =~ Fixture.factory()
      assert details =~ Fixture.strategy()
      assert details =~ "79228162514264337593543900"
      assert details =~ "792281625142643375935439"
      assert details =~ "86401"
      assert details =~ "658201822928399999999999581824872526"
      assert details =~ "0x" <> String.duplicate("ab", 32)
      assert details =~ "Calldata digest"
    end

    test "no governance, receiver or construction control exists anywhere on the page", context do
      view = reviewed(context)
      html = render(view)

      for copy <- @absent_copy, do: refute(html =~ copy)
      refute html =~ "0x783eed53"
      refute html =~ "setLaunchFee"
    end

    test "a zero fee says so plainly and still shows both transactions", context do
      ChainClient.put(Fixture.fixture(fee: 0, allowance: 5 * @unit))
      view = reviewed(context)
      html = render(view)

      assert html =~ "None right now"
      assert html =~ "launch fee is zero right now, so no REGENT moves"
      assert html =~ "Two transactions"
    end

    test "an allowance already equal to the fee is one transaction", context do
      ChainClient.put(Fixture.fixture(allowance: @fee))
      view = reviewed(context)

      assert render(view) =~ "One transaction"
      refute has_element?(view, ~s(#{card(context)} li[data-step="approval"]))
      assert has_element?(view, ~s(#{card(context)} li[data-step="launch"]))
    end

    test "a refusal names the fact that stopped it and offers no send", context do
      ChainClient.put(Fixture.fixture(paused: true))
      view = mounted(context)
      active_wallet(view, card(context), @wallet)

      assert view
             |> element(~s(#{card(context)} button[phx-click="review_launch"]))
             |> render_click() =~ "New launches are paused right now."

      refute has_element?(view, "#{card(context)} [data-launch-wallet-send]")
    end
  end

  describe "THE_BROWSER_REPORTS_A_HASH_AND_STOPS" do
    test "a dispatch is claimed once and the same step is never offered again", context do
      view = reviewed(context)
      operation = open!(context)

      assert has_element?(view, "#{card(context)} [data-launch-wallet-send]")

      render_hook(element(view, card(context)), "sign_launch_step", %{
        "action-id" => operation.action_id
      })

      assert has_element?(view, "#{card(context)} [data-launch-wallet-send]")
      assert render(view) =~ "In your wallet"
    end

    test "a reported hash goes on screen with its transaction link before Base is read",
         context do
      view = submitted(context)

      assert render(view) =~ "Sent"
      assert has_element?(view, ~s(#{card(context)} a[href^="https://basescan.org/tx/"]))
      assert has_element?(view, "#{card(context)} [data-launch-wallet-send]")
    end

    test "an explicit wallet rejection ends the launch and says nothing was sent", context do
      view = reviewed(context)
      operation = open!(context)

      render_hook(element(view, card(context)), "sign_launch_step", %{
        "action-id" => operation.action_id
      })

      html =
        render_hook(element(view, card(context)), "launch_rejected", %{
          "action_id" => operation.action_id,
          "code" => 4001
        })

      assert html =~ "Your wallet declined this. Nothing was sent."
      refute html =~ "data-launch-wallet-send"
    end

    test "a verified launch says exactly what was verified and no more", context do
      view = submitted(context)

      ChainClient.put(%{
        outcomes: %{approval: %{outcome: :confirmed}}
      })

      operation = open!(context)

      html =
        view
        |> element(~s(#{card(context)} button[phx-click="check_launch_step"]))
        |> render_click()

      assert html =~ "Allow the launch fee to be taken"

      # Drive the launch step itself to its verified terminal state.
      ChainClient.put(Fixture.fixture(allowance: @fee))

      render_hook(element(view, card(context)), "sign_launch_step", %{
        "action-id" => operation.action_id
      })

      ChainClient.put(%{outcomes: %{launch: %{outcome: :confirmed, result: %{}}}})

      html =
        render_hook(element(view, card(context)), "launch_submitted", %{
          "action_id" => operation.action_id,
          "step" => "launch",
          "transaction_hash" => @launch_hash
        })

      assert html =~
               "Your transaction and launch record were verified. This launch will appear here when its onchain record is ready."

      # The honest terminal state never claims the launch is already published.
      refute html =~ "Launched"
      refute html =~ "Confirmed on Base"
      refute html =~ "waiting for index"
    end

    test "a review Base has moved past is ended rather than handed to a wallet", context do
      view = reviewed(context)

      ChainClient.put(Fixture.fixture(fee: 2 * @fee))
      operation = open!(context)

      html =
        render_hook(element(view, card(context)), "sign_launch_step", %{
          "action-id" => operation.action_id
        })

      assert html =~ "Base moved on before the launch was sent. Nothing was sent."
      assert html =~ "the launch fee changed after this review"
      refute html =~ "data-launch-wallet-send"
    end
  end

  describe "AN_ENDED_REVIEW_NAMES_THE_ALLOWANCE_IT_LEFT_STANDING" do
    test "a launch invalidated after a verified approval names the standing allowance",
         context do
      {view, operation} = approved(context)

      # Base disagrees with the review the wallet is about to be handed.
      ChainClient.put(Fixture.fixture(fee: 2 * @fee, allowance: @fee))

      html =
        render_hook(element(view, card(context)), "sign_launch_step", %{
          "action-id" => operation.action_id
        })

      refute html =~ "Nothing was sent"
      assert html =~ "Base moved on before the launch was sent."

      assert html =~
               "Your REGENT approval was already sent, so that allowance may still be active."

      assert html =~ "A fresh review corrects that allowance exactly."
      assert html =~ "the launch fee changed after this review"
    end

    test "a launch expired after a verified approval names the standing allowance", context do
      {view, operation} = approved(context)

      elapsed = fn -> DateTime.add(DateTime.utc_now(), 3_600, :second) end
      Application.put_env(:autolaunch, :wallet_action_clock, elapsed)
      on_exit(fn -> Application.delete_env(:autolaunch, :wallet_action_clock) end)

      html =
        render_hook(element(view, card(context)), "sign_launch_step", %{
          "action-id" => operation.action_id
        })

      refute html =~ "Nothing was sent"
      assert html =~ "This review expired before the launch was sent."

      assert html =~
               "Your REGENT approval was already sent, so that allowance may still be active."

      assert html =~ "A fresh review corrects that allowance exactly."
    end
  end

  describe "A_RELOAD_RECOVERS_THE_SERVER_ROW" do
    test "a fresh mount with no browser hint still shows the launch in flight", context do
      _first = submitted(context)

      # A completely new socket, with no stored hint at all.
      view = mounted(context)
      active_wallet(view, card(context), @wallet)

      assert render(view) =~ "Sent"
      assert has_element?(view, ~s(#{card(context)} a[href^="https://basescan.org/tx/"]))
      assert has_element?(view, "#{card(context)} [data-launch-wallet-send]")
    end
  end

  describe "REVOCATION_DENIES_THE_VERY_NEXT_WRITE" do
    test "a mounted socket whose lease is revoked cannot cancel its own review", context do
      {signed_in, view} = mounted_with_conn(context)
      active_wallet(view, card(context), @wallet)

      assert view
             |> element(~s(#{card(context)} button[phx-click="review_launch"]))
             |> render_click() =~ "Review this launch"

      assert SessionAuthority.revoke(claim(signed_in))
      operation = open!(context)

      assert view
             |> element(
               ~s(#{card(context)} button[phx-click="cancel_launch_review"][phx-value-action-id="#{operation.action_id}"])
             )
             |> render_click() =~ "Sign in again to continue."
    end
  end

  # Helpers

  defp card(context), do: "#autolaunch-launch-wallet-#{context[:draft].id}"

  defp mounted(context) do
    {_conn, view} = mounted_with_conn(context)
    view
  end

  defp mounted_with_conn(context) do
    signed_in =
      Phoenix.ConnTest.build_conn()
      |> init_test_session(%{human_account_id: context[:account].id})

    {:ok, view, _html} = live(signed_in, "/create")
    {signed_in, view}
  end

  defp reviewed(context) do
    view = mounted(context)
    active_wallet(view, card(context), @wallet)

    view
    |> element(~s(#{card(context)} button[phx-click="review_launch"]))
    |> render_click()

    view
  end

  defp submitted(context) do
    view = reviewed(context)
    operation = open!(context)

    render_hook(element(view, card(context)), "sign_launch_step", %{
      "action-id" => operation.action_id
    })

    render_hook(element(view, card(context)), "launch_submitted", %{
      "action_id" => operation.action_id,
      "step" => "approval",
      "transaction_hash" => @approval_hash
    })

    view
  end

  # The exact sequence that leaves a REGENT allowance standing on Base: the
  # allowance correction is claimed, its hash is reported, and Base confirms it,
  # so the review moves on to a launch step that has already sent one
  # transaction.
  defp approved(context) do
    view = submitted(context)
    operation = open!(context)

    ChainClient.put(%{outcomes: %{approval: %{outcome: :confirmed}}})

    assert view
           |> element(~s(#{card(context)} button[phx-click="check_launch_step"]))
           |> render_click() =~ "Verified"

    {view, operation}
  end

  # Each saved draft carries its own card, so the wallet is published to the exact
  # one under test rather than to whichever happens to render first.
  defp active_wallet(view, selector, address),
    do:
      render_hook(element(view, selector), "launch_active_wallet", %{
        "address" => address
      })

  defp open!(context) do
    {:ok, %{operation: operation}} = Autolaunch.open_launch_operation(context[:opts])
    operation
  end

  defp claim(conn), do: conn |> get_session() |> SessionAuthority.claim()
end
