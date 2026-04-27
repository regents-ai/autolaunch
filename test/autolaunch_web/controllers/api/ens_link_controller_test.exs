defmodule AutolaunchWeb.Api.EnsLinkControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  setup do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:ens-link-api", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "ENS Operator"
      })

    %{human: human}
  end

  test "planner keeps the stable auth error envelope", %{conn: conn} do
    conn =
      post(conn, "/v1/app/ens/link/plan", %{
        "ens_name" => "agent.eth",
        "chain_id" => "84532",
        "agent_id" => "42"
      })

    assert %{
             "ok" => false,
             "error" => %{"code" => "auth_required", "message" => "Privy session required"}
           } = json_response(conn, 401)
  end

  test "planner keeps the stable validation error envelope", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/v1/app/ens/link/plan", %{
        "ens_name" => "agent.eth",
        "chain_id" => "1",
        "agent_id" => "42"
      })

    assert %{
             "ok" => false,
             "error" => %{"code" => "invalid_chain_id", "message" => "Invalid chain id"}
           } = json_response(conn, 422)
  end
end
