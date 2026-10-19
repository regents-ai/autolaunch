defmodule AutolaunchWeb.SidePanelAgentsTest do
  @moduledoc """
  The side panel lists the person's agents with where each was last active, read
  from the sign-in service only when the panel asks (Sean, 19 Oct 2026, "3. a",
  the template's side panel). A reading the service gives in a shape it does
  not send leaves only that agent's line empty, and the page stays up.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.TestSupport
  alias RegentAgents.{Agent, Person}

  @page "/how-it-works"

  setup do
    Req.Test.set_req_test_to_shared()
    :ok
  end

  # Pairs an agent whose key is `wallet` with the account, as a signed pairing
  # request would.
  defp pair!(account, name, wallet) do
    code = RegentAgents.issue_pairing_code!(actor: %Person{privy_user_id: account.privy_user_id})
    {:ok, agent} = RegentAgents.pair_agent(code.code, name, :codex, actor: %Agent{wallet: wallet})
    agent
  end

  defp wallet(last_digit),
    do: "0x" <> String.pad_leading("#{System.unique_integer([:positive])}#{last_digit}", 40, "0")

  # The sign-in service: one wallet's day is in a shape it never sends, every
  # other agent was last active on Autolaunch five minutes ago.
  defp siwa_answers_activity(broken_wallet) do
    at = DateTime.add(DateTime.utc_now(), -5, :minute)

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"wallet_address" => wallet} = Jason.decode!(body)

      day = %{
        "audience" => "autolaunch",
        "day" => at |> DateTime.to_date() |> Date.to_iso8601(),
        "first_seen_at" => DateTime.to_iso8601(at),
        "last_seen_at" => if(wallet == broken_wallet, do: "", else: DateTime.to_iso8601(at))
      }

      Req.Test.json(conn, %{"data" => %{"days" => [day], "agentRegistration" => nil}})
    end)
  end

  test "SIDE_PANEL_AGENTS_LAST_ACTIVE: the panel lists each agent and where it was last active",
       %{conn: conn} do
    account = TestSupport.register_creator!()
    active = wallet(1)
    broken = wallet(2)
    sol = pair!(account, "Sol", active)
    ada = pair!(account, "Ada", broken)
    siwa_answers_activity(broken)

    {:ok, view, _html} =
      conn |> init_test_session(%{human_account_id: account.id}) |> live(@page)

    # Nothing is read from the sign-in service until the panel asks.
    assert has_element?(view, "#shell-agents-agent-#{sol.id}", "Sol")
    refute render(view) =~ "Active on"

    view |> element("#shell-agents-reader") |> render_hook("read_last_actions", %{})
    render_async(view)

    assert has_element?(view, "#shell-agents-agent-#{sol.id}", "Active on Autolaunch")
    assert has_element?(view, "#shell-agents-agent-#{sol.id} time", "5m")
    assert has_element?(view, "#shell-agents-agent-#{ada.id}", "Ada")
    refute has_element?(view, "#shell-agents-agent-#{ada.id}", "Active on")
    assert has_element?(view, "#shell-pairing", "Pair New Agent")
  end

  test "signed in with no agents, the panel says so; signed out there is no panel",
       %{conn: conn} do
    account = TestSupport.register_creator!()

    {:ok, view, _html} =
      conn |> init_test_session(%{human_account_id: account.id}) |> live(@page)

    assert has_element?(view, "#shell-agents", "No agents paired yet.")

    {:ok, signed_out, _html} = live(conn, @page)
    refute has_element?(signed_out, "#shell-aside")
  end
end
