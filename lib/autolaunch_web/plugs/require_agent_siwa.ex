defmodule AutolaunchWeb.Plugs.RequireAgentSiwa do
  @moduledoc false

  import Plug.Conn

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.HumanUser

  @http_verify_path "/v1/agent/siwa/http-verify"
  @default_connect_timeout_ms 2_000
  @default_receive_timeout_ms 5_000

  def init(opts), do: opts

  def call(conn, _opts) do
    headers =
      conn.req_headers
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        Map.put(acc, String.downcase(key), value)
      end)

    with :ok <- verify_with_broker(conn, headers),
         {:ok, claims} <- extract_claims(headers),
         %HumanUser{} = current_human <- load_current_human(claims) do
      conn
      |> assign(:current_agent_claims, claims)
      |> assign(:current_human, current_human)
    else
      _ -> unauthorized(conn)
    end
  end

  defp verify_with_broker(conn, headers) do
    with {:ok, config} <- fetch_http_config(),
         {:ok, response} <-
           Req.post(
             url: "#{config.internal_url}#{@http_verify_path}",
             json: %{
               "method" => conn.method,
               "path" => conn.request_path,
               "headers" => headers,
               "body_digest" => Map.get(headers, "content-digest")
             },
             connect_options: [timeout: config.connect_timeout_ms],
             receive_timeout: config.receive_timeout_ms
           ) do
      case response do
        %{status: 200, body: %{"ok" => true, "code" => "http_envelope_valid"}} -> :ok
        _ -> {:error, :siwa_auth_denied}
      end
    else
      _ -> {:error, :siwa_auth_denied}
    end
  end

  defp fetch_http_config do
    siwa_cfg = Application.get_env(:autolaunch, :siwa, [])
    internal_url = Keyword.get(siwa_cfg, :internal_url)

    connect_timeout_ms =
      normalize_timeout(
        Keyword.get(siwa_cfg, :http_connect_timeout_ms),
        @default_connect_timeout_ms
      )

    receive_timeout_ms =
      normalize_timeout(
        Keyword.get(siwa_cfg, :http_receive_timeout_ms),
        @default_receive_timeout_ms
      )

    if is_binary(internal_url) and String.trim(internal_url) != "" do
      {:ok,
       %{
         internal_url: String.trim(internal_url),
         connect_timeout_ms: connect_timeout_ms,
         receive_timeout_ms: receive_timeout_ms
       }}
    else
      {:error, :invalid_siwa_config}
    end
  end

  defp extract_claims(headers) do
    with wallet when is_binary(wallet) and wallet != "" <-
           Map.get(headers, "x-agent-wallet-address"),
         chain_id when is_binary(chain_id) and chain_id != "" <-
           Map.get(headers, "x-agent-chain-id") do
      {:ok,
       %{
         "wallet_address" => String.downcase(String.trim(wallet)),
         "chain_id" => String.trim(chain_id),
         "registry_address" =>
           normalize_optional_value(Map.get(headers, "x-agent-registry-address")),
         "token_id" => normalize_optional_value(Map.get(headers, "x-agent-token-id")),
         "label" => normalize_optional_value(Map.get(headers, "x-agent-label"))
       }}
    else
      _ -> {:error, :missing_agent_headers}
    end
  end

  defp load_current_human(%{"wallet_address" => wallet_address}) do
    Accounts.get_human_by_wallet_address(wallet_address)
  end

  defp normalize_timeout(value, _fallback) when is_integer(value) and value > 0, do: value

  defp normalize_timeout(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp normalize_timeout(_value, fallback), do: fallback

  defp normalize_optional_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_value(_value), do: nil

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{
      ok: false,
      error: %{
        code: "siwa_auth_denied",
        message: "Signed agent authentication failed"
      }
    })
    |> halt()
  end
end
