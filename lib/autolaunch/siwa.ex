defmodule Autolaunch.Siwa do
  @moduledoc false

  alias Autolaunch.Siwa.Config

  def issue_nonce(params) do
    payload = %{
      "wallet_address" => Map.fetch!(params, :wallet_address),
      "chain_id" => Map.fetch!(params, :chain_id),
      "registry_address" => Map.fetch!(params, :registry_address),
      "token_id" => Map.fetch!(params, :token_id),
      "audience" => Map.get(params, :audience, "autolaunch")
    }

    proxy("/v1/agent/siwa/nonce", payload)
  end

  def verify_wallet_signature(params) do
    payload =
      %{
        "wallet_address" => Map.fetch!(params, :wallet_address),
        "chain_id" => Map.fetch!(params, :chain_id),
        "registry_address" => Map.fetch!(params, :registry_address),
        "token_id" => Map.fetch!(params, :token_id),
        "nonce" => Map.fetch!(params, :nonce),
        "message" => Map.fetch!(params, :message),
        "signature" => Map.fetch!(params, :signature)
      }

    case proxy("/v1/agent/siwa/verify", payload) do
      {:ok, %{"ok" => true} = response} -> {:ok, response}
      {:ok, response} -> {:error, {:verify_failed, response}}
      {:error, reason} -> {:error, reason}
    end
  end

  def proxy(path, payload) do
    with {:ok, config} <- Config.fetch_http_config(),
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
end
