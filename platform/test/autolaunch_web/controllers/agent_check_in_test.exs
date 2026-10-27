defmodule AutolaunchWeb.AgentCheckInTest do
  @moduledoc """
  An agent's status and check-in on Autolaunch, through the shared agent requests
  this site mounts (`RegentAgents.HTTP`), with the sign-in service stubbed.
  """
  use AutolaunchWeb.ConnCase, async: false

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

  # Pairs this agent's key with `privy_user_id`, whether or not that person has
  # an account.
  defp pair!(conn, privy_user_id) do
    {:ok, code} = RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: privy_user_id})
    body = Jason.encode!(%{"code" => code.code, "name" => "Sol", "harness" => "codex"})
    conn |> post_json("/api/agents/v1/pair", body) |> json_response(201)
  end

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

    assert %{"data" => %{"name" => "Sol", "wallet" => @wallet}} =
             pair!(conn, account.privy_user_id)

    assert %{"data" => %{"status" => "paired", "next_step" => nil, "allowed" => allowed}} =
             conn |> get("/api/agents/v1/whoami") |> json_response(200)

    assert allowed == Application.fetch_env!(:regent_agents, :allowed)["paired"]

    assert %{"data" => %{"wallet" => @wallet, "account" => checked_in_account}} =
             conn |> get("/api/agents/v1/me") |> json_response(200)

    assert checked_in_account["wallet_address"] == account.wallet_address
  end

  # Every status whoami can answer has its own list, so none of them is a 500.
  test "AGENT_WHOAMI_ANSWERS_A_PAIRING_WITHOUT_AN_ACCOUNT", %{conn: conn} do
    siwa_verifies()
    pair!(conn, "did:privy:no-account-#{System.unique_integer([:positive])}")

    assert %{"data" => %{"status" => "person_not_here", "allowed" => allowed}} =
             conn |> get("/api/agents/v1/whoami") |> json_response(200)

    assert allowed == Application.fetch_env!(:regent_agents, :allowed)["person_not_here"]
  end
end
