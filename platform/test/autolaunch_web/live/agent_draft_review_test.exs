defmodule AutolaunchWeb.AgentDraftReviewTest do
  @moduledoc """
  When a paired agent has filled in a launch draft, the person's create page
  names every field the agent set, with its value, above the launch's wallet
  steps; a field the person then changes leaves the list.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
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

  # Production chief, 23 Oct 2026: the box stayed as the page opened while an
  # agent filled in the draft, so the person saw an agent's fields only after
  # a reload.
  test "AGENT_SAVE_SHOWS_LIVE: an open create page shows an agent's save without a reload",
       %{conn: conn} do
    account = TestSupport.register_creator!()

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    RegentAgents.pair_agent!(code.code, "Live Agent", :codex,
      actor: %RegentAgents.Agent{wallet: @wallet}
    )

    {:ok, agent, _account} = Agents.resolve(@wallet)
    session = signed_in_session(account.id)

    for {kind, path} <- [{"revstake", "/create/revstake"}, {"memestock", "/create"}] do
      {:ok, view, _html} =
        conn
        |> Phoenix.ConnTest.init_test_session(session)
        |> connects_with(session)
        |> live(path)

      refute has_element?(view, "#agent-set-fields")

      {:ok, _draft} = AgentDrafts.save(kind, %{"name" => "Agent Live #{kind}"}, agent)

      assert view |> element("#agent-set-fields") |> render() =~ "Agent Live #{kind}"
    end
  end

  # The review is built from the draft as it stands when the person presses
  # Review, so an agent's save after the page opened is named there too.
  test "the launch review names every agent-set field and shows the community links" do
    facts = %{
      "description" => "Earns stablecoins.",
      "website" => "https://autolaunch.sh",
      "telegram" => "https://t.me/agentgroup",
      "discord" => nil,
      "links" => ["https://example.com/one"],
      "image" => "https://autolaunch.sh/images/one/two",
      "agent_set_fields" => ["treasury", "telegram", "other_link_1"]
    }

    assigns = %{facts: facts}
    html = rendered_to_string(~H"<AutolaunchWeb.LaunchSteps.token_rows facts={@facts} />")

    assert html =~ "Set by your agent"
    assert html =~ "Treasury address, Telegram, Link"
    assert html =~ "https://t.me/agentgroup"
    assert html =~ "https://example.com/one"
  end
end
