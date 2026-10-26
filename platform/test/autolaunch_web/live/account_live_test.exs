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
end
