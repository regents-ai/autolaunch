defmodule AutolaunchWeb.Api.ContractsController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Contracts
  alias AutolaunchWeb.Api.ContractsError

  import AutolaunchWeb.Api.ControllerHelpers

  def admin(conn, _params) do
    render_authed(conn, fn _human -> context_module().admin_overview() end)
  end

  def show_job(conn, %{"id" => job_id}) do
    render_authed(conn, fn human -> context_module().job_state(job_id, human) end)
  end

  def show_subject(conn, %{"id" => subject_id}) do
    render_authed(conn, fn human -> context_module().subject_state(subject_id, human) end)
  end

  def prepare_job(conn, %{"id" => job_id, "resource" => resource, "action" => action} = params) do
    render_authed(conn, fn human ->
      context_module().prepare_job_action(job_id, resource, action, params, human)
    end)
  end

  def prepare_subject(
        conn,
        %{"id" => subject_id, "resource" => resource, "action" => action} = params
      ) do
    render_authed(conn, fn human ->
      context_module().prepare_subject_action(subject_id, resource, action, params, human)
    end)
  end

  def prepare_admin(conn, %{"resource" => resource, "action" => action} = params) do
    render_authed(conn, fn _human ->
      context_module().prepare_admin_action(resource, action, params)
    end)
  end

  defp render_result(conn, result),
    do: render_api_result(conn, result, &ContractsError.translate/1)

  defp render_authed(conn, fun) do
    with_current_human(conn, fn human -> render_result(conn, fun.(human)) end, fn conn ->
      render_result(conn, {:error, :unauthorized})
    end)
  end

  defp context_module do
    configured_module(:contracts_api, :context_module, Contracts)
  end
end
