defmodule AutolaunchWeb.AgentTreasuryConfirmTest do
  @moduledoc """
  A Safe or smart contract account a paired agent chose as a Revstake
  launch's treasury receives all its treasury funds, so the launch review is
  prepared only once the person has ticked it, on the create page.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{AgentDrafts, Agents, LaunchActions, LaunchFixture}

  @agent_wallet "0x" <> String.duplicate("ad", 20)
  @contract "0x" <> String.duplicate("5c", 20)
  @other_contract "0x" <> String.duplicate("6d", 20)
  @safe "0x" <> String.duplicate("7e", 20)

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    LaunchFixture.install()
  end

  # Sean, 24 Oct 2026, decision 6a: "Where the money goes should never change
  # without the person noticing." A Safe too: Sean, 26 Oct 2026, "1. a".
  test "AGENT_TREASURY_NEEDS_TICK: an agent's Safe or smart contract treasury launches only after the person ticks it",
       %{conn: conn} do
    setup = LaunchFixture.actor()
    account = setup[:account]

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    RegentAgents.pair_agent!(code.code, "Treasury Agent", :codex,
      actor: %RegentAgents.Agent{wallet: @agent_wallet}
    )

    {:ok, agent, _account} = Agents.resolve(@agent_wallet)

    {:ok, draft} =
      AgentDrafts.save(
        "revstake",
        %{"treasury" => @contract, "treasury_path" => "contract"},
        agent
      )

    assert :agent_treasury_unconfirmed =
             LaunchFixture.refusal(LaunchActions.prepare(draft.id, setup[:wallet], setup[:opts]))

    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/create/revstake")

    assert view |> element("#launch-agent-treasury") |> render() =~ @contract
    refute has_element?(view, "#launch-no-connections")

    # A tick for a treasury the page no longer shows confirms nothing.
    view
    |> element("#launch-agent-treasury")
    |> render_change(%{"treasury" => @other_contract, "confirmed" => "true"})

    assert has_element?(view, "#launch-agent-treasury")

    view
    |> element("#launch-agent-treasury")
    |> render_change(%{"treasury" => @contract, "confirmed" => "true"})

    refute has_element?(view, "#launch-agent-treasury")
    assert has_element?(view, "#launch-no-connections")

    # The review now goes on to the treasury's own checks on Base.
    refute LaunchFixture.refusal(LaunchActions.prepare(draft.id, setup[:wallet], setup[:opts])) ==
             :agent_treasury_unconfirmed

    # The agent then picks a Safe: the person ticks again before the review.
    {:ok, _draft} =
      AgentDrafts.save("revstake", %{"treasury" => @safe, "treasury_path" => "safe"}, agent)

    assert :agent_treasury_unconfirmed =
             LaunchFixture.refusal(LaunchActions.prepare(draft.id, setup[:wallet], setup[:opts]))

    # The page offers a Safe once its own check on Base has found it.
    render_async(view, 5_000)
    assert view |> element("#launch-agent-treasury") |> render() =~ @safe

    view
    |> element("#launch-agent-treasury")
    |> render_change(%{"treasury" => @safe, "confirmed" => "true"})

    refute has_element?(view, "#launch-agent-treasury")

    refute LaunchFixture.refusal(LaunchActions.prepare(draft.id, setup[:wallet], setup[:opts])) ==
             :agent_treasury_unconfirmed
  end
end
