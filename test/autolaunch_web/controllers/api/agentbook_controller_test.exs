defmodule AutolaunchWeb.Api.AgentbookControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  defmodule RegistrationStub do
    def create_session(%{"agent_address" => agent_address, "network" => network}) do
      {:ok,
       %{
         session_id: "sess_1",
         status: :pending,
         agent_address: String.downcase(agent_address),
         network: network,
         chain_id: 480,
         contract_address: "0xA23aB2712eA7BBa896930544C7d6636a96b944dA",
         relay_url: nil,
         nonce: 7,
         app_id: "app_test",
         action: "agentbook-registration",
         rp_id: "app_staging_test",
         signal: "0xsignal",
         rp_context: %{
           nonce: "sig-nonce",
           created_at: 1,
           expires_at: 2,
           signature: "0xsig"
         },
         connector_uri: nil,
         deep_link_uri: nil,
         expires_at: DateTime.utc_now() |> DateTime.add(300, :second),
         proof_payload: nil,
         tx_hash: nil,
         error_text: nil
       }}
    end

    def submit_proof(session, _proof, _options) do
      {:ok,
       session
       |> Map.put(:status, :proof_ready)
       |> Map.put(:error_text, "manual submission requested")
       |> Map.put(:tx_request, %AgentWorld.TxRequest{
         to: session.contract_address,
         data: "0xabc",
         value: "0x0",
         chain_id: session.chain_id,
         description: "Register agent wallet in AgentBook"
       })}
    end

    def register_transaction(tx_hash, session) do
      {:ok, session |> Map.put(:status, :registered) |> Map.put(:tx_hash, tx_hash)}
    end
  end

  defmodule AgentBookStub do
    def resolve_network("world", _opts) do
      {:ok,
       %{
         id: "world",
         chain_id: 480,
         contract_address: "0xA23aB2712eA7BBa896930544C7d6636a96b944dA",
         rpc_url: "https://world.example"
       }}
    end

    def lookup_human(_address, "world", _opts), do: {:ok, "0x1234"}
  end

  setup do
    original = Application.get_env(:autolaunch, :agentbook, [])

    Application.put_env(:autolaunch, :agentbook,
      registration_module: RegistrationStub,
      agent_book_module: AgentBookStub
    )

    on_exit(fn -> Application.put_env(:autolaunch, :agentbook, original) end)
    :ok
  end

  test "creates a public agentbook session", %{conn: conn} do
    conn =
      post(conn, "/api/agentbook/sessions", %{
        "agent_address" => "0x1111111111111111111111111111111111111111",
        "network" => "world",
        "launch_job_id" => "job_followup"
      })

    assert %{
             "ok" => true,
             "session" => %{
               "session_id" => "sess_1",
               "network" => "world",
               "nonce" => 7,
               "launch_job_id" => "job_followup"
             }
           } = json_response(conn, 200)
  end

  test "proof submission returns manual tx fallback when relay is unavailable", %{conn: conn} do
    conn =
      post(conn, "/api/agentbook/sessions", %{
        "agent_address" => "0x1111111111111111111111111111111111111111",
        "network" => "world"
      })

    assert %{"session" => %{"session_id" => session_id}} = json_response(conn, 200)

    conn =
      post(conn, "/api/agentbook/sessions/#{session_id}/submit", %{
        "proof" => %{
          "merkle_root" => "0x01",
          "nullifier_hash" => "0x02",
          "proof" => Enum.map(1..8, &"0x#{Integer.to_string(&1, 16)}")
        }
      })

    assert %{
             "ok" => true,
             "session" => %{
               "status" => "proof_ready",
               "tx_request" => %{"to" => "0xA23aB2712eA7BBa896930544C7d6636a96b944dA"}
             }
           } = json_response(conn, 200)
  end

  test "lookup returns human-backed registration state", %{conn: conn} do
    conn =
      get(conn, "/api/agentbook/lookup", %{
        "agent_address" => "0x1111111111111111111111111111111111111111",
        "network" => "world"
      })

    assert %{
             "ok" => true,
             "result" => %{
               "registered" => true,
               "human_id" => "0x1234",
               "network" => "world"
             }
           } = json_response(conn, 200)
  end

  test "wallet registration writes back the human id", %{conn: conn} do
    conn =
      post(conn, "/api/agentbook/sessions", %{
        "agent_address" => "0x1111111111111111111111111111111111111111",
        "network" => "world",
        "launch_job_id" => "job_followup"
      })

    assert %{"session" => %{"session_id" => session_id}} = json_response(conn, 200)

    conn =
      post(conn, "/api/agentbook/sessions/#{session_id}/submit", %{
        "tx_hash" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      })

    assert %{
             "ok" => true,
             "session" => %{
               "status" => "registered",
               "human_id" => "0x1234",
               "launch_job_id" => "job_followup"
             }
           } = json_response(conn, 200)
  end
end
