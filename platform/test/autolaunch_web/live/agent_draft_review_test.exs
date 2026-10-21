defmodule AutolaunchWeb.AgentDraftReviewTest do
  @moduledoc """
  When a paired agent has filled in a launch draft, the person's create page
  names every field the agent set, with its value, above the launch's wallet
  steps; a field the person then changes leaves the list.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{AgentDrafts, Agents, TestSupport}

  @wallet "0x" <> String.duplicate("ce", 20)
  @treasury "0x" <> String.duplicate("7a", 20)

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
  end

  test "the create page names what the agent set, and forgets a field the person changes",
       %{conn: conn} do
    account = TestSupport.register_creator!()

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    RegentAgents.pair_agent!(code.code, "Review Agent", :codex,
      actor: %RegentAgents.Agent{wallet: @wallet}
    )

    {:ok, agent, _account} = Agents.resolve(@wallet)

    {:ok, _draft} =
      AgentDrafts.save(
        "revstake",
        %{"name" => "Agent Chosen", "treasury" => @treasury, "treasury_path" => "contract"},
        agent
      )

    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/create/revstake")

    review = view |> element("#agent-set-fields") |> render()
    assert review =~ "Agent Chosen"
    assert review =~ @treasury
    assert review =~ "A smart contract account"

    view
    |> form("#launch-token-details", launch_draft: %{name: "Person Chosen"})
    |> render_change()

    review = view |> element("#agent-set-fields") |> render()
    refute review =~ "Agent Chosen"
    assert review =~ @treasury
  end
end
