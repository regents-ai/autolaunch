defmodule AutolaunchWeb.Api.ContractsController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Contracts
  alias AutolaunchWeb.ApiError

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

  defp render_result(conn, {:error, :not_found}) do
    ApiError.render(conn, :not_found, "contract_scope_not_found", "Contract scope was not found")
  end

  defp render_result(conn, {:error, :forbidden}) do
    ApiError.render(
      conn,
      :forbidden,
      "contract_scope_forbidden",
      "Contract action is not allowed"
    )
  end

  defp render_result(conn, {:error, :subject_lookup_failed}) do
    ApiError.render(
      conn,
      :internal_server_error,
      "subject_lookup_failed",
      "Subject state could not be loaded"
    )
  end

  defp render_result(conn, {:error, :unsupported_action}) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "unsupported_contract_action",
      "Contract action is not supported"
    )
  end

  defp render_result(conn, {:error, :ingress_not_found}) do
    ApiError.render(
      conn,
      :not_found,
      "ingress_not_found",
      "Ingress address does not belong to this subject"
    )
  end

  defp render_result(conn, {:error, :invalid_address}) do
    ApiError.render(conn, :unprocessable_entity, "invalid_address", "Address is invalid")
  end

  defp render_result(conn, {:error, :invalid_uint}) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "invalid_amount",
      "Amount must be a whole onchain unit"
    )
  end

  defp render_result(conn, {:error, :invalid_string}) do
    ApiError.render(conn, :unprocessable_entity, "invalid_label", "Text value is required")
  end

  defp render_result(conn, {:error, :invalid_boolean}) do
    ApiError.render(conn, :unprocessable_entity, "invalid_boolean", "Boolean flag is invalid")
  end

  defp render_result(conn, {:error, reason}) do
    ApiError.render(conn, :unprocessable_entity, "contract_prepare_invalid", inspect(reason))
  end

  defp context_module do
    Application.get_env(:autolaunch, :contracts_api, [])
    |> Keyword.get(:context_module, Contracts)
  end
end
