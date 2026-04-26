defmodule Autolaunch.TestSupport.SiwaBrokerStub do
  @moduledoc false

  use Plug.Router

  plug :match
  plug :dispatch

  post "/v1/agent/siwa/http-verify" do
    {:ok, raw_body, conn} = read_body(conn)
    {:ok, decoded} = Jason.decode(raw_body)
    headers = Map.get(decoded, "headers", %{})

    case :persistent_term.get({__MODULE__, :observer}, nil) do
      pid when is_pid(pid) -> send(pid, {:siwa_http_verify, decoded})
      _ -> :ok
    end

    audience = List.first(get_req_header(conn, "x-siwa-audience"))
    secret = Application.get_env(:autolaunch, :siwa, []) |> Keyword.get(:shared_secret)

    case Autolaunch.SiwaReceipt.verify_request_headers(headers,
           audience: audience,
           secret: secret
         ) do
      {:ok, claims} ->
        response = %{
          ok: true,
          code: "http_envelope_valid",
          data: %{
            agent_claims: %{
              wallet_address: claims["sub"],
              chain_id: claims["chain_id"],
              registry_address: claims["registry_address"],
              token_id: claims["token_id"],
              label: Map.get(headers, "x-agent-label")
            }
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))

      {:error, _reason} ->
        response = %{
          ok: false,
          error: %{code: "siwa_auth_denied", message: "Signed agent authentication failed"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(response))
    end
  end

  match _ do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(404, ~s({"ok":false}))
  end
end
