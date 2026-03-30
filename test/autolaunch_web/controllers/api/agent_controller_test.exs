defmodule AutolaunchWeb.Api.AgentControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_agents(nil), do: []

    def list_agents(_human) do
      [
        %{
          agent_id: "11155111:42",
          name: "Atlas",
          state: "eligible",
          supported_chains: [%{id: 11_155_111}]
        },
        %{
          agent_id: "11155111:99",
          name: "Nova",
          state: "already_launched",
          supported_chains: [%{id: 11_155_111}]
        }
      ]
    end

    def get_agent(_human, "missing"), do: nil
    def get_agent(_human, id), do: Enum.find(list_agents(:human), &(&1.agent_id == id))

    def launch_readiness_for_agent(_human, "missing"), do: nil

    def launch_readiness_for_agent(_human, _id) do
      %{
        ready_to_launch: false,
        checks: [
          %{passed: true, message: "Wallet controls this identity."},
          %{passed: false, message: "Launch is already in progress."}
        ]
      }
    end
  end

  setup %{conn: conn} do
    original = Application.get_env(:autolaunch, :agent_controller, [])
    Application.put_env(:autolaunch, :agent_controller, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :agent_controller, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:agent-controller", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Operator"
      })

    %{conn: conn, human: human}
  end

  test "index supports the launchable filter", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    conn = get(conn, "/api/agents?launchable=true")

    assert %{"ok" => true, "items" => [%{"agent_id" => "11155111:42"}]} = json_response(conn, 200)
  end

  test "readiness maps failed checks into launch blockers", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    conn = get(conn, "/api/agents/11155111:42/readiness")

    assert %{
             "ok" => true,
             "launch_eligible" => false,
             "launch_blockers" => ["Launch is already in progress."]
           } = json_response(conn, 200)
  end
end
