defmodule AutolaunchWeb.AgentCheckInTest do
  @moduledoc """
  An agent's status and check-in on Autolaunch, through the shared agent requests
  this site mounts (`RegentAgents.HTTP`) and its own agent routes
  (`AutolaunchWeb.Plugs.AgentAccess`), with the sign-in service stubbed. An agent
  paired by a signed-in person is told it is paired; one whose pairing names no
  Regent account is told it is not paired; and a person's account that could not
  be read just now is 503 `account_unavailable`.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults

  alias Autolaunch.TestSupport
  alias RegentAgents.Person

  @moduletag :capture_log
  @wallet "0x2222222222222222222222222222222222222222"

  # The sign-in service verifies each signed request as this agent's key.
  defp siwa_verifies do
    Req.Test.stub(RegentAgents.Broker, fn conn ->
      Req.Test.json(conn, %{
        "code" => "http_envelope_valid",
        "data" => %{
          "verified" => true,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => @wallet,
            "chain_id" => 8453,
            "audience" => "autolaunch"
          },
          "agentRegistration" => nil,
          "agentBook" => nil
        }
      })
    end)
  end

  # Each request stands for one the agent signed; the stub above verifies it.
  defp post_json(conn, path, body),
    do: conn |> put_req_header("content-type", "application/json") |> post(path, body)

  # AGENT_CHECK_IN_NAMES_THE_SHARED_ACCOUNT: the shared whoami reads what an
  # agent may do from `config :regent_agents, :allowed`, which Autolaunch never
  # set, so every signed whoami answered 500 (found 27 Oct 2026).
  test "AGENT_CHECK_IN_NAMES_THE_SHARED_ACCOUNT: a paired agent is told it is paired and checks in",
       %{conn: conn} do
    siwa_verifies()
    account = TestSupport.register_creator!()

    assert %{"data" => %{"status" => "not_paired", "next_step" => next_step}} =
             conn |> get("/api/agents/v1/whoami") |> json_response(200)

    assert next_step =~ "Pair New Agent"

    {:ok, code} =
      RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: account.privy_user_id})

    body = Jason.encode!(%{"code" => code.code, "name" => "Sol", "harness" => "codex"})

    assert %{"data" => %{"name" => "Sol", "wallet" => @wallet}} =
             conn |> post_json("/api/agents/v1/pair", body) |> json_response(201)

    assert %{"data" => %{"status" => "paired", "next_step" => nil, "allowed" => allowed}} =
             conn |> get("/api/agents/v1/whoami") |> json_response(200)

    assert allowed == Application.fetch_env!(:regent_agents, :allowed)["paired"]

    assert %{"data" => %{"wallet" => @wallet, "account" => checked_in_account}} =
             conn |> get("/api/agents/v1/me") |> json_response(200)

    assert checked_in_account["wallet_address"] == account.wallet_address
  end

  # Pairs this agent's key with `privy_user_id`, whether or not that person has
  # an account.
  defp pair!(conn, privy_user_id) do
    {:ok, code} = RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: privy_user_id})
    body = Jason.encode!(%{"code" => code.code, "name" => "Sol", "harness" => "codex"})
    conn |> post_json("/api/agents/v1/pair", body) |> json_response(201)
  end

  test "AGENT_PAIRING_WITHOUT_ACCOUNT_IS_NOT_PAIRED: a pairing that names no Regent account is agent_not_paired",
       %{conn: conn} do
    siwa_verifies()
    pair!(conn, "did:privy:no-account-#{System.unique_integer([:positive])}")

    for path <- ["/api/agents/v1/me", "/api/agents/v1/whoami"] do
      {403, _headers, body} = assert_error_sent(403, fn -> get(conn, path) end)
      assert %{"error" => %{"code" => "agent_not_paired", "hint" => hint}} = Jason.decode!(body)
      assert hint =~ "Pair New Agent", path
    end

    assert %{"error" => %{"code" => "agent_not_paired", "hint" => hint}} =
             conn |> get("/api/agent/v1/positions") |> json_response(403)

    assert hint =~ "Pair New Agent"
  end

  test "AGENT_PERSON_UNREAD_IS_503: a person's account that can't be read is account_unavailable",
       %{conn: conn} do
    siwa_verifies()
    account = TestSupport.register_creator!()
    pair!(conn, account.privy_user_id)
    lose_reads_of("account_ens_identities")

    for path <- ["/api/agents/v1/me", "/api/agents/v1/whoami"] do
      {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
      assert %{"error" => %{"code" => "account_unavailable"}} = Jason.decode!(body), path
    end

    assert %{"error" => %{"code" => "account_unavailable"}} =
             conn |> get("/api/agent/v1/positions") |> json_response(503)
  end
end
