defmodule AutolaunchWeb.Api.SubjectController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Revenue
  alias AutolaunchWeb.LiveUpdates

  import AutolaunchWeb.Api.ControllerHelpers

  def show(conn, %{"id" => subject_id}) do
    render_result(conn, Revenue.subject_state(subject_id, conn.assigns[:current_human]))
  end

  def ingress(conn, %{"id" => subject_id}) do
    render_result(conn, Revenue.ingress_state(subject_id, conn.assigns[:current_human]))
  end

  def stake(conn, %{"id" => subject_id} = params) do
    render_write(conn, Revenue.stake(subject_id, params, conn.assigns[:current_human]))
  end

  def unstake(conn, %{"id" => subject_id} = params) do
    render_write(conn, Revenue.unstake(subject_id, params, conn.assigns[:current_human]))
  end

  def claim_usdc(conn, %{"id" => subject_id} = params) do
    render_write(conn, Revenue.claim_usdc(subject_id, params, conn.assigns[:current_human]))
  end

  def claim_emissions(conn, %{"id" => subject_id} = params) do
    render_write(conn, Revenue.claim_emissions(subject_id, params, conn.assigns[:current_human]))
  end

  def claim_and_stake_emissions(conn, %{"id" => subject_id} = params) do
    render_write(
      conn,
      Revenue.claim_and_stake_emissions(subject_id, params, conn.assigns[:current_human])
    )
  end

  def sweep_ingress(conn, %{"id" => subject_id, "address" => ingress_address} = params) do
    render_write(
      conn,
      Revenue.sweep_ingress(subject_id, ingress_address, params, conn.assigns[:current_human])
    )
  end

  defp render_write(conn, {:ok, payload}) do
    LiveUpdates.broadcast([:subjects, :positions, :regent])
    render_result(conn, {:ok, payload})
  end

  defp render_write(conn, {:error, _reason} = error), do: render_result(conn, error)

  defp render_result(conn, result), do: render_api_result(conn, result, &translate_error/1)

  defp translate_error(:unauthorized),
    do: {:unauthorized, "auth_required", "Connect a wallet first"}

  defp translate_error(:not_found),
    do: {:not_found, "subject_not_found", "Token page not found"}

  defp translate_error(:subject_lookup_failed),
    do: {:internal_server_error, "subject_lookup_failed", "Token details could not be loaded"}

  defp translate_error(:forbidden),
    do: {:forbidden, "subject_forbidden", "Use the connected wallet"}

  defp translate_error(:transaction_pending),
    do: {:accepted, "transaction_pending", "Transaction is still pending confirmation"}

  defp translate_error(:transaction_failed),
    do: {:unprocessable_entity, "transaction_failed", "The wallet action failed"}

  defp translate_error(:transaction_target_mismatch),
    do: {:forbidden, "transaction_target_mismatch", "This wallet action is for a different token"}

  defp translate_error(:transaction_hash_reused),
    do: {:conflict, "transaction_hash_reused", "Transaction hash has already been registered"}

  defp translate_error(:transaction_data_mismatch),
    do:
      {:unprocessable_entity, "transaction_data_mismatch",
       "This wallet action does not match the selected action"}

  defp translate_error(:invalid_transaction_hash),
    do: {:unprocessable_entity, "invalid_transaction_hash", "Transaction hash is invalid"}

  defp translate_error(:invalid_subject_id),
    do: {:unprocessable_entity, "invalid_subject_id", "Token page is invalid"}

  defp translate_error(:invalid_amount),
    do: {:unprocessable_entity, "invalid_amount", "Amount is invalid"}

  defp translate_error(:invalid_amount_precision),
    do: {:unprocessable_entity, "invalid_amount_precision", "Amount precision is too high"}

  defp translate_error(:amount_required),
    do: {:unprocessable_entity, "amount_required", "Amount is required"}

  defp translate_error(:invalid_ingress_address),
    do: {:unprocessable_entity, "invalid_ingress_address", "USDC intake address is invalid"}

  defp translate_error(:ingress_not_found),
    do: {:not_found, "ingress_not_found", "USDC intake address does not belong to this token"}

  defp translate_error(:invalid_source_ref),
    do: {:unprocessable_entity, "invalid_source_ref", "Source reference is invalid"}

  defp translate_error(reason),
    do: {:unprocessable_entity, "subject_invalid", inspect(reason)}
end
