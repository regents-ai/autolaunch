defmodule AutolaunchWeb.Api.LifecycleController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Lifecycle

  import AutolaunchWeb.Api.ControllerHelpers

  def show_job(conn, %{"id" => job_id}) do
    render_result(conn, context_module().job_summary(job_id, conn.assigns[:current_human]))
  end

  def prepare_finalize(conn, %{"id" => job_id}) do
    render_result(conn, context_module().prepare_finalize(job_id, conn.assigns[:current_human]))
  end

  def register_finalize(conn, %{"id" => job_id} = params) do
    render_result(
      conn,
      context_module().register_finalize(job_id, params, conn.assigns[:current_human])
    )
  end

  def vesting(conn, %{"id" => job_id}) do
    render_result(conn, context_module().vesting_status(job_id, conn.assigns[:current_human]))
  end

  defp render_result(conn, result), do: render_api_result(conn, result, &translate_error/1)

  defp translate_error(:not_found),
    do: {:not_found, "lifecycle_not_found", "Lifecycle job was not found"}

  defp translate_error(:forbidden),
    do: {:forbidden, "lifecycle_forbidden", "Lifecycle action is not allowed"}

  defp translate_error(:unauthorized),
    do: {:unauthorized, "auth_required", "Privy session required"}

  defp translate_error(:job_lookup_failed),
    do: {:internal_server_error, "job_lookup_failed", "Lifecycle job could not be loaded"}

  defp translate_error(:invalid_transaction_hash),
    do: {:unprocessable_entity, "invalid_transaction_hash", "Transaction hash is invalid"}

  defp translate_error(reason),
    do: {:unprocessable_entity, "lifecycle_invalid", inspect(reason)}

  defp context_module do
    configured_module(:lifecycle_api, :context_module, Lifecycle)
  end
end
