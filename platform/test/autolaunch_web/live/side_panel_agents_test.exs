defmodule AutolaunchWeb.SidePanelAgentsTest do
  @moduledoc """
  The side panel lists the person's agents with where each was last active, read
  from the sign-in service only when the panel asks (Sean, 19 Oct 2026, "3. a",
  the template's side panel). Each agent's reading is shared by every page for
  five minutes; a failed one, including a read that raises, is counted by reason
  and kept for one minute, so the service is not asked again meanwhile. A day in
  a shape the service never sends leaves only that agent's line empty, and the
  page stays up.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Agents.ActivityReading
  alias Autolaunch.TestSupport
  alias RegentAgents.{Agent, PairedAgent, Person}

  @page "/how-it-works"

  setup do
    Req.Test.set_req_test_to_shared()
    test = self()
    handler = "activity-unread-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:autolaunch, :agents, :activity_unread],
      fn _event, %{count: 1}, %{reason: reason}, _config -> send(test, {:unread, reason}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  # Pairs an agent whose key is `wallet` with the account, as a signed pairing
  # request would.
  defp pair!(account, name, wallet) do
    code = RegentAgents.issue_pairing_code!(actor: %Person{privy_user_id: account.privy_user_id})
    {:ok, agent} = RegentAgents.pair_agent(code.code, name, :codex, actor: %Agent{wallet: wallet})
    agent
  end

  defp wallet,
    do: "0x" <> String.pad_leading("#{System.unique_integer([:positive])}", 40, "0")

  defp agent(wallet), do: %PairedAgent{wallet: wallet, paired_at: ~U[2026-10-01 00:00:00Z]}

  # The sign-in service, which tells this case each wallet it is asked about.
  # One wallet's day is in a shape it never sends; every other agent was last
  # active on Autolaunch five minutes ago.
  defp siwa_answers_activity(broken_wallet) do
    test = self()
    at = DateTime.add(DateTime.utc_now(), -5, :minute)

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"wallet_address" => wallet} = Jason.decode!(body)
      send(test, {:activity_read, wallet})

      day = %{
        "audience" => "autolaunch",
        "day" => at |> DateTime.to_date() |> Date.to_iso8601(),
        "first_seen_at" => DateTime.to_iso8601(at),
        "last_seen_at" => if(wallet == broken_wallet, do: "", else: DateTime.to_iso8601(at))
      }

      Req.Test.json(conn, %{"data" => %{"days" => [day], "agentRegistration" => nil}})
    end)
  end

  defp open_panel(view) do
    view |> element("#shell-agents-reader") |> render_hook("read_last_actions", %{})
    render_async(view)
  end

  test "SIDE_PANEL_AGENTS_LAST_ACTIVE: the panel lists each agent and where it was last active",
       %{conn: conn} do
    account = TestSupport.register_creator!()
    active = wallet()
    broken = wallet()
    sol = pair!(account, "Sol", active)
    ada = pair!(account, "Ada", broken)
    siwa_answers_activity(broken)
    conn = init_test_session(conn, %{human_account_id: account.id})

    {:ok, view, _html} = live(conn, @page)

    # The agents are listed, and nothing is asked of the sign-in service until
    # the panel opens.
    assert has_element?(view, "#shell-agents-agent-#{sol.id}", "Sol")
    refute_received {:activity_read, _wallet}

    open_panel(view)
    assert_received {:activity_read, ^active}
    assert_received {:activity_read, ^broken}
    assert_received {:unread, :bad_day}

    assert has_element?(view, "#shell-agents-agent-#{sol.id}", "Active on Autolaunch")
    assert has_element?(view, "#shell-agents-agent-#{sol.id} time", "5m")
    assert has_element?(view, "#shell-agents-agent-#{ada.id}", "Ada")
    refute has_element?(view, "#shell-agents-agent-#{ada.id}", "Active on")
    assert has_element?(view, "#shell-pairing", "Pair New Agent")

    # Another open page shows the same readings without asking again.
    {:ok, other, _html} = live(conn, @page)
    open_panel(other)
    refute_received {:activity_read, _wallet}
    refute_received {:unread, _reason}
    assert has_element?(other, "#shell-agents-agent-#{sol.id}", "Active on Autolaunch")
  end

  test "a failed reading is counted and kept for a minute" do
    test = self()
    failing = wallet()

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      send(test, :activity_read)
      Plug.Conn.send_resp(conn, 500, "")
    end)

    assert ActivityReading.read(agent(failing)) == {:error, {:unexpected_status, 500}}
    assert_received :activity_read
    assert_received {:unread, :unexpected_status}

    assert ActivityReading.read(agent(failing)) == {:error, {:unexpected_status, 500}}
    refute_received :activity_read
    refute_received {:unread, _reason}

    {:ok, kept_ms} = Cachex.ttl(ActivityReading.cache(), {failing, agent(failing).paired_at})
    assert kept_ms in 55_000..60_000
  end

  test "ACTIVITY_READ_THAT_RAISES_IS_KEPT: a read that raises is counted and kept for a minute" do
    test = self()
    raising = wallet()

    Req.Test.stub(RegentAgents.Broker, fn _conn ->
      send(test, :activity_read)
      raise "the sign-in service answered in a way nothing here reads"
    end)

    assert ActivityReading.read(agent(raising)) == {:error, :raised}
    assert_received :activity_read
    assert_received {:unread, :raised}

    assert ActivityReading.read(agent(raising)) == {:error, :raised}
    refute_received :activity_read
    refute_received {:unread, _reason}

    {:ok, kept_ms} = Cachex.ttl(ActivityReading.cache(), {raising, agent(raising).paired_at})
    assert kept_ms in 55_000..60_000
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
