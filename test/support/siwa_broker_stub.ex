defmodule Autolaunch.TestSupport.SiwaBrokerStub do
  use Plug.Router

  plug :match
  plug :dispatch

  post "/v1/agent/siwa/http-verify" do
    {:ok, raw_body, conn} = read_body(conn)
    {:ok, decoded} = Jason.decode(raw_body)
    headers = Map.get(decoded, "headers", %{})

    response = %{
      ok: true,
      code: "http_envelope_valid",
      data: %{
        agent_claims: %{
          wallet_address: Map.get(headers, "x-agent-wallet-address"),
          chain_id: Map.get(headers, "x-agent-chain-id"),
          registry_address: Map.get(headers, "x-agent-registry-address"),
          token_id: Map.get(headers, "x-agent-token-id"),
          label: Map.get(headers, "x-agent-label")
        }
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  match _ do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(404, ~s({"ok":false}))
  end
end
