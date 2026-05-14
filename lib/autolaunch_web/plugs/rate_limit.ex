defmodule AutolaunchWeb.Plugs.RateLimit do
  @moduledoc false

  import Plug.Conn

  alias AutolaunchWeb.ApiError
  alias AutolaunchWeb.RateLimiter

  @public_write_limit [limit: 60, window_ms: 60_000]
  @expensive_read_limit [limit: 120, window_ms: 60_000]
  @session_write_limit [limit: 60, window_ms: 60_000]
  @session_read_limit [limit: 180, window_ms: 60_000]
  @signed_agent_write_limit [limit: 240, window_ms: 60_000]
  @signed_agent_read_limit [limit: 600, window_ms: 60_000]

  def init(opts), do: opts

  def call(%Plug.Conn{private: %{autolaunch_rate_limited: true}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn = put_private(conn, :autolaunch_rate_limited, true)

    if enabled?() do
      apply_rule(conn, matching_rule(conn))
    else
      conn
    end
  end

  defp apply_rule(conn, nil), do: conn

  defp apply_rule(conn, {name, defaults, key_strategy}) do
    config = configured_limit(name, defaults)
    key = {name, client_key(conn, key_strategy), conn.method, conn.request_path}

    case RateLimiter.check(
           key,
           Keyword.fetch!(config, :limit),
           Keyword.fetch!(config, :window_ms)
         ) do
      :ok ->
        conn

      {:error, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", retry_after_seconds(retry_after_ms))
        |> ApiError.render(
          :too_many_requests,
          "rate_limited",
          "Please wait a moment before trying again.",
          %{retry_after_ms: retry_after_ms}
        )
        |> halt()
    end
  end

  defp matching_rule(%Plug.Conn{request_path: "/health"}), do: nil

  defp matching_rule(%Plug.Conn{method: method, request_path: path} = conn)
       when method in ["POST", "PATCH", "DELETE"] do
    cond do
      signed_agent_path?(path) and signed_agent_request?(conn) ->
        {:signed_agent_write, @signed_agent_write_limit, :agent}

      session_path?(path) and session_request?(conn) ->
        {:session_write, @session_write_limit, :session}

      public_write_path?(path) ->
        {:public_write, @public_write_limit, :ip}

      true ->
        nil
    end
  end

  defp matching_rule(%Plug.Conn{method: "GET", request_path: path} = conn) do
    cond do
      signed_agent_path?(path) and signed_agent_request?(conn) ->
        {:signed_agent_read, @signed_agent_read_limit, :agent}

      session_path?(path) and session_request?(conn) ->
        {:session_read, @session_read_limit, :session}

      expensive_read_path?(path) ->
        {:expensive_read, @expensive_read_limit, :ip}

      true ->
        nil
    end
  end

  defp matching_rule(_conn), do: nil

  defp enabled? do
    :autolaunch
    |> Application.get_env(:rate_limits, [])
    |> Keyword.get(:enabled, true)
  end

  defp configured_limit(name, defaults) do
    configured =
      :autolaunch
      |> Application.get_env(:rate_limits, [])
      |> Keyword.get(name, [])

    Keyword.merge(defaults, configured)
  end

  defp public_write_path?(path) do
    String.starts_with?(path, ["/v1/app", "/v1/agent", "/v1/auth"])
  end

  defp session_path?(path) do
    String.starts_with?(path, ["/v1/app", "/v1/auth"])
  end

  defp signed_agent_path?(path), do: String.starts_with?(path, ["/v1/agent", "/v1/auth/agent"])

  defp signed_agent_request?(conn), do: is_map(conn.assigns[:current_agent_claims])

  defp session_request?(%Plug.Conn{private: %{plug_session_fetch: :done}} = conn) do
    non_empty_session_value?(get_session(conn, :privy_user_id)) or
      non_empty_session_value?(get_session(conn, "privy_user_id"))
  end

  defp session_request?(_conn), do: false

  defp non_empty_session_value?(value), do: is_binary(value) and value != ""

  defp session_value(%Plug.Conn{private: %{plug_session_fetch: :done}} = conn) do
    get_session(conn, :privy_user_id) || get_session(conn, "privy_user_id")
  end

  defp session_value(_conn), do: nil

  defp expensive_read_path?(path) do
    Enum.any?(
      [
        "/v1/app/me",
        "/v1/app/agentbook/lookup",
        "/v1/app/regent/staking/account",
        "/v1/app/contracts",
        "/v1/app/subjects",
        "/v1/app/launch/jobs",
        "/v1/app/prelaunch/plans",
        "/v1/agent/contracts",
        "/v1/agent/subjects",
        "/v1/agent/launch/jobs",
        "/v1/agent/prelaunch/plans"
      ],
      &String.starts_with?(path, &1)
    )
  end

  defp client_key(conn, :agent) do
    case conn.assigns[:current_agent_claims] do
      %{} = claims ->
        [
          "agent",
          claim_value(claims, "wallet_address"),
          claim_value(claims, "chain_id"),
          claim_value(claims, "registry_address"),
          claim_value(claims, "token_id")
        ]
        |> Enum.join(":")

      _claims ->
        client_key(conn, :ip)
    end
  end

  defp client_key(conn, :session) do
    case session_value(conn) do
      value when is_binary(value) and value != "" -> "session:#{value}"
      _value -> client_key(conn, :ip)
    end
  end

  defp client_key(conn, _strategy), do: client_ip(conn)

  defp client_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp claim_value(claims, key) do
    claims
    |> Map.get(key)
    |> to_string()
    |> String.downcase()
  end

  defp retry_after_seconds(retry_after_ms) do
    retry_after_ms
    |> Kernel./(1000)
    |> Float.ceil()
    |> trunc()
    |> max(1)
    |> Integer.to_string()
  end
end
