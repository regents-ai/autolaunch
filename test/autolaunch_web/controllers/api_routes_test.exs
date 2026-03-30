defmodule AutolaunchWeb.ApiRoutesTest do
  use AutolaunchWeb.ConnCase, async: true

  test "root serves the public guide", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ "How autolaunch auctions work."
  end

  test "auction index returns JSON", %{conn: conn} do
    conn = get(conn, "/api/auctions")

    assert %{"ok" => true, "items" => items} = json_response(conn, 200)
    assert is_list(items)
  end

  test "launch preview requires auth", %{conn: conn} do
    conn =
      post(conn, "/api/launch/preview", %{
        "agent_id" => "ag_research",
        "token_name" => "Agent Coin",
        "token_symbol" => "AGENT",
        "recovery_safe_address" => "0x0000000000000000000000000000000000000001",
        "auction_proceeds_recipient" => "0x0000000000000000000000000000000000000001",
        "ethereum_revenue_treasury" => "0x0000000000000000000000000000000000000001"
      })

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} = json_response(conn, 401)
  end

  test "siwa nonce rejects invalid chain ids", %{conn: conn} do
    conn =
      post(conn, "/v1/agent/siwa/nonce", %{
        "walletAddress" => "0x0000000000000000000000000000000000000001",
        "chainId" => "10"
      })

    assert %{"ok" => false, "error" => %{"code" => "invalid_chain_id"}} = json_response(conn, 422)
  end

  test "ens link planner requires auth", %{conn: conn} do
    conn =
      post(conn, "/api/ens/link/plan", %{
        "ens_name" => "vitalik.eth",
        "chain_id" => "1",
        "agent_id" => "42"
      })

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} = json_response(conn, 401)
  end

  test "subject routes are wired", %{conn: conn} do
    conn = get(conn, "/api/subjects/not-a-valid-subject")

    assert %{"ok" => false, "error" => %{"code" => "invalid_subject_id"}} =
             json_response(conn, 422)
  end
end
