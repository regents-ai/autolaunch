defmodule AutolaunchWeb.Api.LifecycleController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Lifecycle
  alias AutolaunchWeb.ApiError

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

  defp render_result(conn, {:ok, payload}), do: json(conn, Map.put(payload, :ok, true))

  defp render_result(conn, {:error, :not_found}) do
    ApiError.render(conn, :not_found, "lifecycle_not_found", "Lifecycle job was not found")
  end

  defp render_result(conn, {:error, :forbidden}) do
    ApiError.render(conn, :forbidden, "lifecycle_forbidden", "Lifecycle action is not allowed")
  end

  defp render_result(conn, {:error, :invalid_transaction_hash}) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "invalid_transaction_hash",
      "Transaction hash is invalid"
    )
  end

  defp render_result(conn, {:error, reason}) do
    ApiError.render(conn, :unprocessable_entity, "lifecycle_invalid", inspect(reason))
  end

  defp context_module do
    Application.get_env(:autolaunch, :lifecycle_api, [])
    |> Keyword.get(:context_module, Lifecycle)
  end
end
