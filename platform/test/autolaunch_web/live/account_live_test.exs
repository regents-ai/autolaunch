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
end
