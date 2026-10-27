defmodule AutolaunchWeb.AccountLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  @moduletag :capture_log

  # ACCOUNT_SHOWS_A_PAIRED_AGENT: the shared agents list needs every field of a
  # row this page builds; a missing `kind` crashed /account for everyone with a
  # paired agent (v140), and no case had a paired agent. The row's `wallet` is
  # what puts the agent's address beside its name.
  test "ACCOUNT_SHOWS_A_PAIRED_AGENT", %{conn: conn} do
    account = TestSupport.register_creator!()

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    agent =
      RegentAgents.pair_agent!(code.code, "Account Page Agent", :codex,
        actor: %RegentAgents.Agent{wallet: "0x" <> String.duplicate("ab", 20)}
      )

    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/account")

    render_async(view, 1_000)
    agents = view |> element("#account-agents") |> render()
    assert agents =~ "Account Page Agent"
    assert agents =~ "Codex"
    assert has_element?(view, "#account-agents-agent-#{agent.id}-wallet")
  end

  # ACCOUNT_SHOWS_CREDITS_HISTORY: the shared Credits library names each history
  # entry by `kind`, `amount` and `direction`; this page still read the earlier
  # entry fields, so /account crashed and reloaded every second for everyone
  # who had bought Credits (v180), and no case had any Credits history.
  test "ACCOUNT_SHOWS_CREDITS_HISTORY", %{conn: conn} do
    account = TestSupport.register_creator!()

    # A paid purchase, recorded and credited as the chain check does once the
    # payment lands; there is no chain in tests to check.
    purchase =
      RegentCredits.Purchase
      |> Ash.Changeset.for_create(
        :record,
        %{
          privy_user_id: account.privy_user_id,
          wallet: String.downcase(account.wallet_address),
          chain: :base,
          amount: 5,
          number: Ecto.UUID.generate(),
          tx_hash: "0x" <> String.duplicate("cd", 32)
        },
        authorize?: false
      )
      |> Ash.create!()

    RegentCredits.Purchase
    |> Ash.ActionInput.for_action(:credit, %{id: purchase.id}, authorize?: false)
    |> Ash.run_action!()

    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/account")

    render_async(view, 1_000)
    history = view |> element("#account-credits-history") |> render()
    assert history =~ "Bought Credits"
    assert history =~ "+5"
  end

  # PAIRING_CODE_KEPT_PER_AGENT: the pairing box held one code and made a new one
  # on every agent choice, so choosing Codex, then Hermes, then Codex again showed
  # a third code and the message already pasted to Codex no longer matched the
  # screen (27 Oct 2026). Each agent now keeps its code until it expires, and
  # "Make a new code" replaces only the chosen agent's, as ash-template's box does.
  test "PAIRING_CODE_KEPT_PER_AGENT", %{conn: conn} do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/account")

    render_async(view, 1_000)
    box = form(view, "#account-agents-pair")
    shown = fn -> pairing_code(view) end

    render_change(box, %{harness: "codex"})
    codex = shown.()
    render_change(box, %{harness: "hermes"})
    hermes = shown.()
    render_change(box, %{harness: "codex"})

    assert codex != hermes
    assert shown.() == codex

    render_submit(box, %{harness: "codex"})
    renewed = shown.()
    assert renewed != codex

    render_change(box, %{harness: "hermes"})
    assert shown.() == hermes
    render_change(box, %{harness: "codex"})
    assert shown.() == renewed
  end

  # The code in the message the box shows for the chosen agent.
  defp pairing_code(view) do
    message = view |> element("#account-agents-pair pre:not([data-unused])") |> render()
    [_, code] = Regex.run(~r/Pairing code:\s*([^\s<]+)/, message)
    code
  end
end
