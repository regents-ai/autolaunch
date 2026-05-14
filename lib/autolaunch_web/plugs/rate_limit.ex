defmodule AutolaunchWeb.Plugs.RateLimit do
  @moduledoc false

  import Plug.Conn

  alias AutolaunchWeb.ApiError
  alias AutolaunchWeb.RateLimiter

  @public_write_limit [limit: 60, window_ms: 60_000]
  @expensive_read_limit [limit: 120, window_ms: 60_000]

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

  defp apply_rule(conn, {name, defaults}) do
    config = configured_limit(name, defaults)
    key = {name, client_ip(conn), conn.request_path}

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

  defp matching_rule(%Plug.Conn{method: method, request_path: path})
       when method in ["POST", "PATCH", "DELETE"] do
    if public_write_path?(path), do: {:public_write, @public_write_limit}
  end

  defp matching_rule(%Plug.Conn{method: "GET", request_path: path}) do
    if expensive_read_path?(path), do: {:expensive_read, @expensive_read_limit}
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

  defp client_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
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
