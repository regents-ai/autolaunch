defmodule Autolaunch.Siwa do
  @moduledoc false

  @default_connect_timeout_ms 2_000
  @default_receive_timeout_ms 5_000

  def issue_nonce(params) do
    payload = %{
      "wallet_address" => Map.fetch!(params, :wallet_address),
      "chain_id" => Map.fetch!(params, :chain_id),
      "audience" => Map.get(params, :audience, "autolaunch")
    }

    proxy("/v1/agent/siwa/nonce", payload)
  end

  def verify_wallet_signature(params) do
    payload =
      %{
        "wallet_address" => Map.fetch!(params, :wallet_address),
        "chain_id" => Map.fetch!(params, :chain_id),
        "nonce" => Map.fetch!(params, :nonce),
        "message" => Map.fetch!(params, :message),
        "signature" => Map.fetch!(params, :signature)
      }
      |> maybe_put("registry_address", Map.get(params, :registry_address))
      |> maybe_put("token_id", Map.get(params, :token_id))

    case proxy("/v1/agent/siwa/verify", payload) do
      {:ok, %{"ok" => true} = response} -> {:ok, response}
      {:ok, response} -> {:error, {:verify_failed, response}}
      {:error, reason} -> {:error, reason}
    end
  end

  def proxy(path, payload) do
    with {:ok, config} <- fetch_http_config(),
         {:ok, response} <-
           Req.post(
             url: "#{config.internal_url}#{path}",
             json: payload,
             connect_options: [timeout: config.connect_timeout_ms],
             receive_timeout: config.receive_timeout_ms
           ) do
      case response do
        %{status: status, body: body} when status in 200..299 ->
          {:ok, body}

        %{status: status, body: body} ->
          {:error, {:sidecar_error, status, body}}
      end
    else
      {:error, reason} -> {:error, reason}
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

    if is_binary(internal_url) and internal_url != "" do
      {:ok,
       %{
         internal_url: internal_url,
         connect_timeout_ms: connect_timeout_ms,
         receive_timeout_ms: receive_timeout_ms
       }}
    else
      {:error, :invalid_siwa_config}
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
