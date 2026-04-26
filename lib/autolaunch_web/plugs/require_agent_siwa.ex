defmodule AutolaunchWeb.Plugs.RequireAgentSiwa do
  @moduledoc false

  import Plug.Conn

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Siwa.Config

  @http_verify_path "/v1/agent/siwa/http-verify"
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

    with {:ok, claims} <- verify_with_broker(conn, headers) do
      conn
      |> assign(:current_agent_claims, claims)
      |> maybe_assign_current_human(claims)
    else
      _ -> unauthorized(conn)
    end
  end

  defp verify_with_broker(conn, headers) do
    with {:ok, config} <- Config.fetch_http_config(),
         {:ok, response} <-
           Req.post(
             url: "#{config.internal_url}#{@http_verify_path}",
             json: build_http_verify_payload(conn, headers),
             headers: [{"x-siwa-audience", @audience}],
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

  defp normalize_claims(claims) when is_map(claims) do
    with {:ok, wallet} <- required_claim_value(claims, "wallet_address"),
         :ok <- ensure_hex_address(wallet),
         {:ok, chain_id} <- required_claim_value(claims, "chain_id"),
         :ok <- ensure_positive_int(chain_id),
         {:ok, registry_address} <- required_claim_value(claims, "registry_address"),
         :ok <- ensure_hex_address(registry_address),
         {:ok, token_id} <- required_claim_value(claims, "token_id"),
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

  defp build_http_verify_payload(conn, headers) do
    base_payload = %{
      "method" => conn.method,
      "path" => signed_path(conn),
      "headers" => headers
    }

    case conn.assigns[:raw_body] do
      value when is_binary(value) -> Map.put(base_payload, "body", value)
      _ -> base_payload
    end
  end

  defp signed_path(%{request_path: path, query_string: ""}), do: path
  defp signed_path(%{request_path: path, query_string: query}), do: path <> "?" <> query

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

  defp required_claim_value(claims, key) when is_map(claims) do
    case claims[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_agent_headers}
          trimmed -> {:ok, trimmed}
        end

      value when is_integer(value) ->
        {:ok, Integer.to_string(value)}

      _ ->
        {:error, :missing_agent_headers}
    end
  end

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
