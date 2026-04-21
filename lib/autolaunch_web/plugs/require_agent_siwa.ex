defmodule AutolaunchWeb.Plugs.RequireAgentSiwa do
  @moduledoc false

  import Plug.Conn

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.SiwaReceipt

  @http_verify_path "/v1/agent/siwa/http-verify"
  @default_connect_timeout_ms 2_000
  @default_receive_timeout_ms 5_000
  @audience "autolaunch"
  @hex_address_regex ~r/^0x[0-9a-fA-F]{40}$/
  @positive_int_regex ~r/^[1-9][0-9]*$/

  def init(opts), do: opts

  def call(conn, _opts) do
    headers =
      conn.req_headers
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        Map.put(acc, String.downcase(key), value)
      end)

    with :ok <- verify_receipt(headers),
         {:ok, claims} <- verify_with_broker(conn, headers) do
      conn
      |> assign(:current_agent_claims, claims)
      |> maybe_assign_current_human(claims)
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
        %{
          status: 200,
          body: %{
            "ok" => true,
            "code" => "http_envelope_valid",
            "data" => %{"agent_claims" => claims}
          }
        } ->
          normalize_claims(claims)

        _ ->
          {:error, :siwa_auth_denied}
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

  defp normalize_claims(claims) when is_map(claims) do
    with wallet when is_binary(wallet) <- claims["wallet_address"],
         :ok <- ensure_hex_address(wallet),
         chain_id when is_binary(chain_id) <- claims["chain_id"],
         :ok <- ensure_positive_int(chain_id),
         registry_address when is_binary(registry_address) <- claims["registry_address"],
         :ok <- ensure_hex_address(registry_address),
         token_id when is_binary(token_id) <- claims["token_id"],
         :ok <- ensure_positive_int(token_id) do
      {:ok,
       %{
         "wallet_address" => String.downcase(String.trim(wallet)),
         "chain_id" => String.trim(chain_id),
         "registry_address" => String.downcase(String.trim(registry_address)),
         "token_id" => String.trim(token_id),
         "label" => normalize_optional_value(claims["label"])
       }}
    else
      _ -> {:error, :missing_agent_headers}
    end
  end

  defp normalize_claims(_claims), do: {:error, :missing_agent_headers}

  defp load_current_human(%{"wallet_address" => wallet_address}) do
    Accounts.get_human_by_wallet_address(wallet_address)
  end

  defp maybe_assign_current_human(conn, claims) do
    case load_current_human(claims) do
      %HumanUser{} = current_human -> assign(conn, :current_human, current_human)
      _ -> conn
    end
  end

  defp normalize_timeout(value, _fallback) when is_integer(value) and value > 0, do: value

  defp normalize_timeout(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp normalize_timeout(_value, fallback), do: fallback

  defp verify_receipt(headers) do
    with {:ok, secret} <- fetch_shared_secret() do
      case SiwaReceipt.verify_request_headers(headers, audience: @audience, secret: secret) do
        {:ok, _claims} -> :ok
        {:error, _reason} -> {:error, :siwa_auth_denied}
      end
    end
  end

  defp fetch_shared_secret do
    case Application.get_env(:autolaunch, :siwa, []) |> Keyword.get(:shared_secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :invalid_siwa_config}
    end
  end

  defp ensure_hex_address(value) when is_binary(value) do
    if value =~ @hex_address_regex, do: :ok, else: {:error, :invalid_agent_header}
  end

  defp ensure_hex_address(_value), do: {:error, :invalid_agent_header}

  defp ensure_positive_int(value) when is_binary(value) do
    if value =~ @positive_int_regex, do: :ok, else: {:error, :invalid_agent_header}
  end

  defp ensure_positive_int(_value), do: {:error, :invalid_agent_header}

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
