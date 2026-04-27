defmodule AutolaunchWeb.Api.ControllerHelpers do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]

  alias AutolaunchWeb.ApiError

  def with_current_human(conn, fun) when is_function(fun, 1) do
    with_current_human(conn, fun, &render_auth_required/1)
  end

  def with_current_human(conn, fun, on_missing)
      when is_function(fun, 1) and is_function(on_missing, 1) do
    case conn.assigns[:current_human] do
      nil -> on_missing.(conn)
      current_human -> fun.(current_human)
    end
  end

  def configured_module(config_key, module_key, default_module) do
    :autolaunch
    |> Application.get_env(config_key, [])
    |> Keyword.get(module_key, default_module)
  end

  def render_api_result(conn, result, translate_error) do
    render_api_result(conn, result, translate_error, [])
  end

  def render_api_result(conn, {:ok, payload}, _translate_error, opts) do
    payload =
      case Keyword.get(opts, :root_key) do
        nil -> payload
        key -> %{key => payload}
      end

    json(conn, Map.put(payload, :ok, true))
  end

  def render_api_result(conn, {:error, reason}, translate_error, _opts)
      when is_function(translate_error, 1) do
    reason
    |> translate_error.()
    |> render_translated_error(conn)
  end

  defp render_translated_error({status, code, message}, conn) do
    ApiError.render(conn, status, code, message)
  end

  defp render_translated_error({status, code, message, meta}, conn) do
    ApiError.render(conn, status, code, message, meta)
  end

  defp render_auth_required(conn) do
    ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")
  end
end
