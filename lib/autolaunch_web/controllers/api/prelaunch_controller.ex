defmodule AutolaunchWeb.Api.PrelaunchController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Prelaunch
  alias AutolaunchWeb.ClientIp

  import AutolaunchWeb.Api.ControllerHelpers

  def index(conn, _params) do
    render_result(conn, context_module().list_plans(current_actor(conn)), :plans)
  end

  def create(conn, params) do
    render_result(conn, context_module().create_plan(params, current_actor(conn)), :plan,
      status: :created
    )
  end

  def show(conn, %{"id" => plan_id}) do
    render_result(conn, context_module().get_plan(plan_id, current_actor(conn)), :plan)
  end

  def update(conn, %{"id" => plan_id} = params) do
    render_result(
      conn,
      context_module().update_plan(plan_id, params, current_actor(conn)),
      :plan
    )
  end

  def validate(conn, %{"id" => plan_id}) do
    render_result(
      conn,
      context_module().validate_plan(plan_id, current_actor(conn)),
      nil
    )
  end

  def publish(conn, %{"id" => plan_id}) do
    render_result(
      conn,
      context_module().publish_plan(plan_id, current_actor(conn)),
      nil
    )
  end

  def launch(conn, %{"id" => plan_id} = params) do
    render_result(
      conn,
      context_module().launch_plan(
        plan_id,
        params,
        current_actor(conn),
        ClientIp.from_conn(conn)
      ),
      nil
    )
  end

  def upload_asset(conn, params) do
    render_result(
      conn,
      context_module().upload_asset(params, current_actor(conn)),
      :asset
    )
  end

  def metadata(conn, %{"id" => plan_id} = params) do
    render_result(
      conn,
      context_module().update_metadata(plan_id, params, current_actor(conn)),
      nil
    )
  end

  def metadata_preview(conn, %{"id" => plan_id}) do
    render_result(
      conn,
      context_module().metadata_preview(plan_id, current_actor(conn)),
      :metadata_preview
    )
  end

  defp render_result(conn, result, root_key, opts \\ []),
    do:
      render_api_result(
        conn,
        result,
        &translate_error/1,
        Keyword.merge([root_key: root_key], opts)
      )

  defp translate_error(:unauthorized),
    do: {:unauthorized, "auth_required", "Signed agent or connected wallet required"}

  defp translate_error(:not_found),
    do: {:not_found, "prelaunch_plan_not_found", "Prelaunch plan not found"}

  defp translate_error(:agent_not_found),
    do: {:not_found, "agent_not_found", "Agent not found"}

  defp translate_error(:not_launchable),
    do: {:unprocessable_entity, "prelaunch_not_launchable", "Prelaunch plan still has blockers"}

  defp translate_error(:invalid_media_type),
    do:
      {:unprocessable_entity, "invalid_media_type", "Image type must be png, jpeg, webp, or gif"}

  defp translate_error(:metadata_required),
    do: {:unprocessable_entity, "metadata_required", "Metadata is required"}

  defp translate_error(_reason),
    do: {:unprocessable_entity, "prelaunch_invalid", "Prelaunch request could not be completed"}

  defp context_module do
    configured_module(:prelaunch_api, :context_module, Prelaunch)
  end

  defp current_actor(conn),
    do: conn.assigns[:current_agent_claims] || conn.assigns[:current_human]
end
