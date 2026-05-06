defmodule AutolaunchWeb.Plugs.RequireInternalSignature do
  @moduledoc false

  import Plug.Conn

  alias AutolaunchWeb.ApiError

  @signature_header "x-autolaunch-signature"
  @timestamp_header "x-autolaunch-timestamp"
  @signature_prefix "v1="
  @max_clock_skew_seconds 300

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    with {:ok, secret} <- fetch_secret(),
         {:ok, timestamp} <- fetch_timestamp(conn),
         :ok <- verify_timestamp(timestamp),
         {:ok, provided_signature} <- fetch_signature(conn),
         expected_signature <- build_signature(secret, timestamp, conn),
         true <- secure_equals?(provided_signature, expected_signature) do
      conn
    else
      _error -> unauthorized(conn)
    end
  end

  defp fetch_secret do
    case Application.get_env(:autolaunch, :internal_shared_secret, "") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_secret}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, :invalid_secret}
    end
  end

  defp fetch_timestamp(conn) do
    with [value | _rest] <- get_req_header(conn, @timestamp_header),
         {timestamp, ""} <- value |> String.trim() |> Integer.parse() do
      {:ok, timestamp}
    else
      _error -> {:error, :invalid_timestamp}
    end
  end

  defp verify_timestamp(timestamp) do
    if abs(System.system_time(:second) - timestamp) <= @max_clock_skew_seconds do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end

  defp fetch_signature(conn) do
    case get_req_header(conn, @signature_header) do
      [@signature_prefix <> signature | _rest] -> normalize_signature(signature)
      _other -> {:error, :missing_signature}
    end
  end

  defp normalize_signature(signature) do
    normalized = signature |> String.trim() |> String.downcase()

    if Regex.match?(~r/\A[0-9a-f]{64}\z/, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_signature}
    end
  end

  defp build_signature(secret, timestamp, conn) do
    :hmac
    |> :crypto.mac(:sha256, secret, signed_payload(timestamp, conn))
    |> Base.encode16(case: :lower)
  end

  defp signed_payload(timestamp, conn) do
    [
      Integer.to_string(timestamp),
      conn.method,
      signed_path(conn),
      body_digest(conn)
    ]
    |> Enum.join("\n")
  end

  defp signed_path(%Plug.Conn{query_string: ""} = conn), do: conn.request_path
  defp signed_path(conn), do: conn.request_path <> "?" <> conn.query_string

  defp body_digest(conn) do
    conn
    |> raw_body()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp raw_body(%Plug.Conn{assigns: %{raw_body: body}}) when is_binary(body), do: body
  defp raw_body(_conn), do: ""

  defp secure_equals?(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equals?(_left, _right), do: false

  defp unauthorized(conn) do
    conn
    |> ApiError.render(:unauthorized, "internal_auth_required", "Internal auth required")
    |> halt()
  end
end
