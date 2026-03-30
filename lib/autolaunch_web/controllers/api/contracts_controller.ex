defmodule AutolaunchWeb.Api.ContractsController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Contracts
  alias AutolaunchWeb.Api.ContractsError

  def admin(conn, _params) do
    render_result(conn, context_module().admin_overview())
  end

  def show_job(conn, %{"id" => job_id}) do
    render_result(conn, context_module().job_state(job_id, conn.assigns[:current_human]))
  end

  def show_subject(conn, %{"id" => subject_id}) do
    render_result(conn, context_module().subject_state(subject_id, conn.assigns[:current_human]))
  end

  def prepare_job(conn, %{"id" => job_id, "resource" => resource, "action" => action} = params) do
    render_result(
      conn,
      context_module().prepare_job_action(
        job_id,
        resource,
        action,
        params,
        conn.assigns[:current_human]
      )
    )
  end

  def prepare_subject(
        conn,
        %{"id" => subject_id, "resource" => resource, "action" => action} = params
      ) do
    render_result(
      conn,
      context_module().prepare_subject_action(
        subject_id,
        resource,
        action,
        params,
        conn.assigns[:current_human]
      )
    )
  end

  def prepare_admin(conn, %{"resource" => resource, "action" => action} = params) do
    render_result(conn, context_module().prepare_admin_action(resource, action, params))
  end

  defp render_result(conn, {:ok, payload}), do: json(conn, Map.put(payload, :ok, true))
  defp render_result(conn, {:error, _reason} = error), do: ContractsError.render(conn, error)

  defp context_module do
    Application.get_env(:autolaunch, :contracts_api, [])
    |> Keyword.get(:context_module, Contracts)
  end
end
