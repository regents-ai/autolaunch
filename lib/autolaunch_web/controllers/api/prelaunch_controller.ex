defmodule AutolaunchWeb.Api.PrelaunchController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Prelaunch
  alias AutolaunchWeb.ApiError

  def index(conn, _params) do
    render_result(conn, context_module().list_plans(conn.assigns[:current_human]), :plans)
  end

  def create(conn, params) do
    render_result(conn, context_module().create_plan(params, conn.assigns[:current_human]), :plan)
  end

  def show(conn, %{"id" => plan_id}) do
    render_result(conn, context_module().get_plan(plan_id, conn.assigns[:current_human]), :plan)
  end

  def update(conn, %{"id" => plan_id} = params) do
    render_result(
      conn,
      context_module().update_plan(plan_id, params, conn.assigns[:current_human]),
      :plan
    )
  end

  def validate(conn, %{"id" => plan_id}) do
    render_result(
      conn,
      context_module().validate_plan(plan_id, conn.assigns[:current_human]),
      nil
    )
  end

  def publish(conn, %{"id" => plan_id}) do
    render_result(
      conn,
      context_module().publish_plan(plan_id, conn.assigns[:current_human]),
      nil
    )
  end

  def launch(conn, %{"id" => plan_id} = params) do
    render_result(
      conn,
      context_module().launch_plan(
        plan_id,
        params,
        conn.assigns[:current_human],
        client_ip(conn)
      ),
      nil
    )
  end

  def upload_asset(conn, params) do
    render_result(
      conn,
      context_module().upload_asset(params, conn.assigns[:current_human]),
      :asset
    )
  end

  def metadata(conn, %{"id" => plan_id} = params) do
    render_result(
      conn,
      context_module().update_metadata(plan_id, params, conn.assigns[:current_human]),
      nil
    )
  end

  def metadata_preview(conn, %{"id" => plan_id}) do
    render_result(
      conn,
      context_module().metadata_preview(plan_id, conn.assigns[:current_human]),
      :metadata_preview
    )
  end

  defp render_result(conn, {:ok, payload}, root_key)
       when is_binary(root_key) or is_atom(root_key) do
    payload =
      case root_key do
        nil -> payload
        key -> %{key => payload}
      end

    json(conn, Map.put(payload, :ok, true))
  end

  defp render_result(conn, {:ok, payload}, nil), do: json(conn, Map.put(payload, :ok, true))

  defp render_result(conn, {:error, :unauthorized}, _root_key) do
    ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")
  end

  defp render_result(conn, {:error, :not_found}, _root_key) do
    ApiError.render(conn, :not_found, "prelaunch_plan_not_found", "Prelaunch plan not found")
  end

  defp render_result(conn, {:error, :agent_not_found}, _root_key) do
    ApiError.render(conn, :not_found, "agent_not_found", "Agent not found")
  end

  defp render_result(conn, {:error, :not_launchable}, _root_key) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "prelaunch_not_launchable",
      "Prelaunch plan still has blockers"
    )
  end

  defp render_result(conn, {:error, :invalid_media_type}, _root_key) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "invalid_media_type",
      "Image type must be png, jpeg, webp, or gif"
    )
  end

  defp render_result(conn, {:error, reason}, _root_key) do
    ApiError.render(conn, :unprocessable_entity, "prelaunch_invalid", inspect(reason))
  end

  defp context_module do
    Application.get_env(:autolaunch, :prelaunch_api, [])
    |> Keyword.get(:context_module, Prelaunch)
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",", parts: 2) |> hd() |> String.trim()
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
