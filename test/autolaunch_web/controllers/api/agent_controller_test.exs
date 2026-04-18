defmodule AutolaunchWeb.Api.AgentControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_agents(nil) do
      [
        %{
          agent_id: "84532:42",
          name: "Atlas",
          state: "eligible",
          supported_chains: [%{id: 84_532}]
        }
      ]
    end

    def list_agents(_human) do
      [
        %{
          agent_id: "84532:42",
          name: "Atlas",
          state: "eligible",
          supported_chains: [%{id: 84_532}]
        },
        %{
          agent_id: "84532:99",
          name: "Nova",
          state: "already_launched",
          supported_chains: [%{id: 84_532}]
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

    assert %{"ok" => true, "items" => items} = json_response(conn, 200)
    assert Enum.any?(items, &(&1["agent_id"] == "84532:42"))
  end

  test "readiness maps failed checks into launch blockers", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    conn = get(conn, "/api/agents/84532:42/readiness")

    assert %{
             "ok" => true,
             "launch_eligible" => false,
             "launch_blockers" => ["Launch is already in progress."]
           } = json_response(conn, 200)
  end

  test "agent route works without a linked human session", %{conn: conn} do
    original_siwa_cfg = Application.get_env(:autolaunch, :siwa, [])
    port = available_port()

    start_supervised!(
      {Bandit,
       plug: Autolaunch.TestSupport.SiwaBrokerStub, ip: {127, 0, 0, 1}, port: port}
    )

    Application.put_env(:autolaunch, :siwa,
      internal_url: "http://127.0.0.1:#{port}",
      http_connect_timeout_ms: 2_000,
      http_receive_timeout_ms: 5_000
    )

    on_exit(fn -> Application.put_env(:autolaunch, :siwa, original_siwa_cfg) end)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-agent-wallet-address", @wallet)
      |> put_req_header("x-agent-chain-id", "84532")
      |> put_req_header("x-agent-registry-address", "0x2222222222222222222222222222222222222222")
      |> put_req_header("x-agent-token-id", "44")
      |> get("/v1/agent/agents")

    assert %{"ok" => true, "items" => items} = json_response(conn, 200)
    assert Enum.any?(items, &(&1["agent_id"] == "84532:42"))
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
