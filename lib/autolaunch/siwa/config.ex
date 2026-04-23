defmodule Autolaunch.Siwa.Config do
  @moduledoc false

  @default_connect_timeout_ms 2_000
  @default_receive_timeout_ms 5_000

  @type http_config :: %{
          internal_url: String.t(),
          connect_timeout_ms: pos_integer(),
          receive_timeout_ms: pos_integer()
        }

  @spec fetch_http_config() ::
          {:ok, http_config()}
          | {:error, :invalid_siwa_config | {:invalid_siwa_timeout, atom()}}
  def fetch_http_config do
    siwa_cfg = Application.get_env(:autolaunch, :siwa, [])

    with {:ok, internal_url} <- fetch_internal_url(siwa_cfg),
         {:ok, connect_timeout_ms} <-
           fetch_timeout(
             siwa_cfg,
             :http_connect_timeout_ms,
             @default_connect_timeout_ms
           ),
         {:ok, receive_timeout_ms} <-
           fetch_timeout(
             siwa_cfg,
             :http_receive_timeout_ms,
             @default_receive_timeout_ms
           ) do
      {:ok,
       %{
         internal_url: internal_url,
         connect_timeout_ms: connect_timeout_ms,
         receive_timeout_ms: receive_timeout_ms
       }}
    end
  end

  defp fetch_internal_url(siwa_cfg) do
    case Keyword.get(siwa_cfg, :internal_url) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :invalid_siwa_config}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :invalid_siwa_config}
    end
  end

  defp fetch_timeout(siwa_cfg, key, default) do
    case Keyword.fetch(siwa_cfg, key) do
      {:ok, value} -> parse_timeout(value, key)
      :error -> {:ok, default}
    end
  end

  defp parse_timeout(value, _key) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_timeout(value, key) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, {:invalid_siwa_timeout, key}}
    end
  end

  defp parse_timeout(_value, key), do: {:error, {:invalid_siwa_timeout, key}}
end
