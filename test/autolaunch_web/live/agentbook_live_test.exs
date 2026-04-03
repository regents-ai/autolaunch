defmodule AutolaunchWeb.AgentbookLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defmodule ContextStub do
    def list_recent_sessions do
      [
        %{
          session_id: "recent_1",
          status: "registered",
          agent_address: "0x1111111111111111111111111111111111111111",
          network: "world"
        }
      ]
    end

    def create_session(%{"agent_address" => agent_address, "network" => network}) do
      {:ok,
       %{
         session_id: "sess_live",
         status: "pending",
         agent_address: agent_address,
         network: network,
         chain_id: 480,
         contract_address: "0xA23aB2712eA7BBa896930544C7d6636a96b944dA",
         nonce: 9,
         connector_uri: nil,
         deep_link_uri: nil,
         tx_hash: nil,
         error_text: nil,
         frontend_request: %{
           app_id: "app_test",
           action: "agentbook-registration",
           rp_context: %{nonce: "n", created_at: 1, expires_at: 2, signature: "0xsig"},
           signal: "0xsignal"
         }
       }}
    end

    def submit_session("sess_live", %{"proof" => _proof}) do
      {:ok,
       %{
         session_id: "sess_live",
         status: "proof_ready",
         agent_address: "0x1111111111111111111111111111111111111111",
         network: "world",
         chain_id: 480,
         contract_address: "0xA23aB2712eA7BBa896930544C7d6636a96b944dA",
         nonce: 9,
         deep_link_uri: "worldapp://verify",
         tx_request: %{
           to: "0xA23aB2712eA7BBa896930544C7d6636a96b944dA",
           data: "0xabc",
           value: "0x0",
           chain_id: 480
         }
       }}
    end

    def submit_session("sess_live", %{"tx_hash" => tx_hash}) do
      {:ok,
       %{
         session_id: "sess_live",
         status: "registered",
         agent_address: "0x1111111111111111111111111111111111111111",
         network: "world",
         chain_id: 480,
         contract_address: "0xA23aB2712eA7BBa896930544C7d6636a96b944dA",
         nonce: 9,
         deep_link_uri: "worldapp://verify",
         tx_hash: tx_hash
       }}
    end

    def store_connector_uri("sess_live", connector_uri) do
      {:ok,
       %{
         session_id: "sess_live",
         status: "pending",
         agent_address: "0x1111111111111111111111111111111111111111",
         network: "world",
         chain_id: 480,
         contract_address: "0xA23aB2712eA7BBa896930544C7d6636a96b944dA",
         nonce: 9,
         connector_uri: connector_uri,
         deep_link_uri: connector_uri,
         frontend_request: %{
           app_id: "app_test",
           action: "agentbook-registration",
           rp_context: %{nonce: "n", created_at: 1, expires_at: 2, signature: "0xsig"},
           signal: "0xsignal"
         }
       }}
    end

    def fail_session(_session_id, _message), do: {:ok, :ignored}

    def get_session("sess_live") do
      %{
        session_id: "sess_live",
        status: "failed",
        agent_address: "0x1111111111111111111111111111111111111111",
        network: "world"
      }
    end

    def lookup_human(%{"agent_address" => _, "network" => "world"}) do
      {:ok,
       %{
         registered: true,
         human_id: "0x1234",
         agent_address: "0x1111111111111111111111111111111111111111",
         network: "world",
         contract_address: "0xA23aB2712eA7BBa896930544C7d6636a96b944dA"
       }}
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :agentbook_live, [])
    Application.put_env(:autolaunch, :agentbook_live, context_module: ContextStub)
    on_exit(fn -> Application.put_env(:autolaunch, :agentbook_live, original) end)
    :ok
  end

  test "public page renders register and lookup panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agentbook")

    assert html =~ "Register agent wallet"
    assert html =~ "Lookup human-backed status"
    assert html =~ "No Privy needed"
  end

  test "launch follow-up query preloads the world proof form", %{conn: conn} do
    {:ok, _view, html} =
      live(
        conn,
        "/agentbook?agent_address=0x1111111111111111111111111111111111111111&network=world&launch_job_id=job_followup"
      )

    assert html =~ "job_followup"
    assert html =~ "0x1111111111111111111111111111111111111111"
    assert html =~ "Launch follow-up"
  end

  test "creating a session and receiving proof shows manual register action", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agentbook")

    html =
      view
      |> form("form[phx-submit='create_session']", %{
        "register" => %{
          "agent_address" => "0x1111111111111111111111111111111111111111",
          "network" => "world"
        }
      })
      |> render_submit()

    assert html =~ "Waiting for World App"
    assert html =~ "Nonce 9"

    html =
      render_hook(view, "agentbook_proof_ready", %{
        "session_id" => "sess_live",
        "proof" => %{
          "merkle_root" => "0x01",
          "nullifier_hash" => "0x02",
          "proof" => Enum.map(1..8, &"0x#{Integer.to_string(&1, 16)}")
        }
      })

    assert html =~ "Proof verified"
    assert html =~ "Send register transaction"
  end
end
