defmodule Autolaunch.SiwaReceipt do
  @moduledoc false

  @hex_address_regex ~r/^0x[0-9a-fA-F]{40}$/
  @positive_int_regex ~r/^[1-9][0-9]*$/

  @type claims :: %{
          required(:typ) => String.t(),
          required(:sub) => String.t(),
          required(:aud) => String.t(),
          required(:iat) => integer(),
          required(:exp) => integer(),
          required(:chainId) => integer(),
          required(:nonce) => String.t(),
          required(:keyId) => String.t(),
          required(:registryAddress) => String.t(),
          required(:tokenId) => String.t()
        }

  def verify_request_headers(headers, opts) when is_map(headers) and is_list(opts) do
    expected_audience = Keyword.fetch!(opts, :audience)
    secret = Keyword.fetch!(opts, :secret)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, token} <- fetch_header(headers, "x-siwa-receipt"),
         {:ok, claims} <- verify_token(token, secret, now: now),
         :ok <- ensure_audience(claims, expected_audience),
         :ok <- ensure_bound_claims(claims, headers) do
      {:ok, claims}
    end
  end

  def verify_token(token, secret, opts \\ [])

  def verify_token(token, secret, opts) when is_binary(token) and is_binary(secret) do
    now_unix_seconds =
      opts
      |> Keyword.get(:now, DateTime.utc_now())
      |> DateTime.to_unix()

    with [header_segment, payload_segment, signature_segment] <- String.split(token, "."),
         :ok <- verify_signature(header_segment, payload_segment, signature_segment, secret),
         {:ok, header_json} <- decode_segment(header_segment),
         {:ok, payload_json} <- decode_segment(payload_segment),
         :ok <- validate_header(header_json),
         {:ok, claims} <- validate_claims(payload_json),
         :ok <- ensure_not_expired(claims, now_unix_seconds) do
      {:ok, claims}
    else
      _ -> {:error, :receipt_invalid}
    end
  end

  def verify_token(_token, _secret, _opts), do: {:error, :receipt_invalid}

  defp fetch_header(headers, key) do
    case Map.get(headers, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :receipt_missing}
    end
  end

  defp verify_signature(header_segment, payload_segment, signature_segment, secret) do
    expected_signature =
      :crypto.mac(:hmac, :sha256, secret, "#{header_segment}.#{payload_segment}")
      |> Base.url_encode64(padding: false)

    if Plug.Crypto.secure_compare(signature_segment, expected_signature) do
      :ok
    else
      {:error, :receipt_invalid}
    end
  end

  defp decode_segment(segment) do
    with {:ok, decoded} <- Base.url_decode64(segment, padding: false),
         {:ok, json} <- Jason.decode(decoded) do
      {:ok, json}
    else
      _ -> {:error, :receipt_invalid}
    end
  end

  defp validate_header(%{"alg" => "HS256", "typ" => "JWT"}), do: :ok
  defp validate_header(_header), do: {:error, :receipt_invalid}

  defp validate_claims(
         %{
           "typ" => "siwa_receipt",
           "sub" => sub,
           "aud" => aud,
           "iat" => iat,
           "exp" => exp,
           "chainId" => chain_id,
           "nonce" => nonce,
           "keyId" => key_id,
           "registryAddress" => registry_address,
           "tokenId" => token_id
         } = claims
       )
       when is_binary(sub) and is_binary(aud) and is_integer(iat) and is_integer(exp) and
              is_integer(chain_id) and is_binary(nonce) and is_binary(key_id) and
              is_binary(registry_address) and is_binary(token_id) do
    cond do
      claims["typ"] != "siwa_receipt" -> {:error, :receipt_invalid}
      aud == "" -> {:error, :receipt_invalid}
      iat <= 0 or exp <= iat -> {:error, :receipt_invalid}
      chain_id <= 0 -> {:error, :receipt_invalid}
      nonce == "" or key_id == "" -> {:error, :receipt_invalid}
      not (sub =~ @hex_address_regex) -> {:error, :receipt_invalid}
      not (registry_address =~ @hex_address_regex) -> {:error, :receipt_invalid}
      not (token_id =~ @positive_int_regex) -> {:error, :receipt_invalid}
      true -> {:ok, claims}
    end
  end

  defp validate_claims(_claims), do: {:error, :receipt_invalid}

  defp ensure_not_expired(%{"exp" => exp}, now_unix_seconds) when now_unix_seconds <= exp, do: :ok
  defp ensure_not_expired(_claims, _now_unix_seconds), do: {:error, :receipt_expired}

  defp ensure_audience(%{"aud" => audience}, expected_audience)
       when audience == expected_audience,
       do: :ok

  defp ensure_audience(_claims, _expected_audience), do: {:error, :receipt_audience_mismatch}

  defp ensure_bound_claims(claims, headers) do
    with {:ok, wallet_address} <- fetch_header(headers, "x-agent-wallet-address"),
         {:ok, chain_id} <- fetch_header(headers, "x-agent-chain-id"),
         {:ok, registry_address} <- fetch_header(headers, "x-agent-registry-address"),
         {:ok, token_id} <- fetch_header(headers, "x-agent-token-id"),
         true <- String.downcase(wallet_address) == String.downcase(claims["sub"]),
         true <- chain_id == Integer.to_string(claims["chainId"]),
         true <- String.downcase(registry_address) == String.downcase(claims["registryAddress"]),
         true <- token_id == claims["tokenId"] do
      :ok
    else
      _ -> {:error, :receipt_binding_mismatch}
    end
  end
end
