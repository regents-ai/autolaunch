defmodule AutolaunchWeb.AgentCheckInTest do
  @moduledoc """
  An agent's status and check-in on Autolaunch, through the shared agent requests
  this site mounts (`RegentAgents.HTTP`), with the sign-in service stubbed. Every
  person has one Regent account on every Regent site, so an agent paired by a
  signed-in person is never told its person is missing here.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport
  alias RegentAgents.Person

  @wallet "0x2222222222222222222222222222222222222222"
  @never ["person not here", "person_not_here", "not on this site", "owner_not_local"]

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

    whoami = conn |> get("/api/agents/v1/whoami") |> json_response(200)

    assert %{"data" => %{"status" => "paired", "next_step" => nil, "allowed" => allowed}} =
             whoami

    assert allowed == Application.fetch_env!(:regent_agents, :allowed)["paired"]

    check_in = conn |> get("/api/agents/v1/me") |> json_response(200)

    assert %{"data" => %{"wallet" => @wallet, "account" => checked_in_account}} = check_in
    assert checked_in_account["wallet_address"] == account.wallet_address

    for answer <- [whoami, check_in], words <- @never do
      refute Jason.encode!(answer) =~ words
    end
  end
end
