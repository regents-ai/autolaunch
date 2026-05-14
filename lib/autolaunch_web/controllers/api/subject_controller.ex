defmodule AutolaunchWeb.Api.SubjectController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Revenue
  alias AutolaunchWeb.LiveUpdates

  import AutolaunchWeb.Api.ControllerHelpers

  def show(conn, %{"id" => subject_id}) do
    render_result(conn, context_module().subject_state(subject_id, current_actor(conn)))
  end

  def ingress(conn, %{"id" => subject_id}) do
    render_result(conn, context_module().ingress_state(subject_id, current_actor(conn)))
  end

  def accounting_tags(conn, %{"id" => subject_id} = params) do
    render_result(conn, context_module().accounting_tags(subject_id, params, current_actor(conn)))
  end

  def prepare_existing_token(conn, params) do
    render_write(
      conn,
      context_module().prepare_existing_token_subject(params, current_actor(conn))
    )
  end

  def confirm_existing_token(conn, params) do
    render_write(
      conn,
      context_module().confirm_existing_token_subject(params, current_actor(conn))
    )
  end

  def prepare_deferred_autolaunch(conn, params) do
    render_write(conn, context_module().prepare_deferred_autolaunch(params, current_actor(conn)))
  end

  def confirm_deferred_autolaunch(conn, params) do
    render_write(conn, context_module().confirm_deferred_autolaunch(params, current_actor(conn)))
  end

  def by_token(conn, %{"token" => token}) do
    render_result(conn, context_module().subjects_by_token(token))
  end

  def staking(conn, %{"id" => subject_id}) do
    render_result(conn, context_module().subject_staking(subject_id))
  end

  def protocol_fee_settlements(conn, %{"id" => subject_id}) do
    render_result(conn, context_module().subject_protocol_fee_settlements(subject_id))
  end

  def regent_emissions(conn, %{"id" => subject_id}) do
    render_result(conn, context_module().subject_regent_emissions(subject_id))
  end

  def stake(conn, %{"id" => subject_id} = params) do
    render_write(conn, context_module().stake(subject_id, params, current_actor(conn)))
  end

  def unstake(conn, %{"id" => subject_id} = params) do
    render_write(conn, context_module().unstake(subject_id, params, current_actor(conn)))
  end

  def claim_usdc(conn, %{"id" => subject_id} = params) do
    render_write(conn, context_module().claim_usdc(subject_id, params, current_actor(conn)))
  end

  def sweep_ingress(conn, %{"id" => subject_id, "address" => ingress_address} = params) do
    render_write(
      conn,
      context_module().sweep_ingress(subject_id, ingress_address, params, current_actor(conn))
    )
  end

  defp render_write(conn, {:ok, %{prepared: _prepared} = payload}) do
    render_result(conn, {:ok, payload})
  end

  defp render_write(conn, {:ok, payload}) do
    LiveUpdates.broadcast([:subjects, :positions, :regent])
    render_result(conn, {:ok, payload})
  end

  defp render_write(conn, {:error, _reason} = error), do: render_result(conn, error)

  defp render_result(conn, result), do: render_api_result(conn, result, &translate_error/1)

  defp current_actor(conn),
    do: conn.assigns[:current_agent_claims] || conn.assigns[:current_human]

  defp context_module do
    configured_module(:subject_api, :context_module, Revenue)
  end

  defp translate_error(:unauthorized),
    do: {:unauthorized, "auth_required", "Signed agent or connected wallet required"}

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

  defp translate_error(:invalid_address),
    do: {:unprocessable_entity, "invalid_address", "Wallet address is invalid"}

  defp translate_error(:invalid_ingress_address),
    do: {:unprocessable_entity, "invalid_ingress_address", "USDC intake address is invalid"}

  defp translate_error(:ingress_not_found),
    do: {:not_found, "ingress_not_found", "USDC intake address does not belong to this token"}

  defp translate_error(:factory_unconfigured),
    do:
      {:unprocessable_entity, "factory_unconfigured",
       "This subject creation path is not configured yet"}

  defp translate_error(:revenue_subject_not_found),
    do: {:not_found, "subject_not_found", "Token page not found"}

  defp translate_error(:invalid_subject_token),
    do: {:unprocessable_entity, "invalid_subject_token", "Token address is invalid"}

  defp translate_error(:invalid_label),
    do: {:unprocessable_entity, "invalid_label", "Name is required"}

  defp translate_error(:invalid_uint),
    do: {:unprocessable_entity, "invalid_number", "Number is invalid"}

  defp translate_error(:invalid_bytes32),
    do: {:unprocessable_entity, "invalid_hex", "Hex value is invalid"}

  defp translate_error(:invalid_hex),
    do: {:unprocessable_entity, "invalid_hex", "Hex value is invalid"}

  defp translate_error(:invalid_identity),
    do: {:unprocessable_entity, "invalid_identity", "Identity details are incomplete"}

  defp translate_error(:transaction_receipt_unavailable),
    do:
      {:bad_gateway, "transaction_receipt_unavailable",
       "Transaction details could not be loaded right now"}

  defp translate_error(:creation_event_not_found),
    do:
      {:unprocessable_entity, "creation_event_not_found",
       "This transaction did not create the requested subject"}

  defp translate_error(:invalid_creation_event),
    do:
      {:unprocessable_entity, "invalid_creation_event",
       "This subject creation transaction could not be read"}

  defp translate_error(:from_block_required),
    do: {:unprocessable_entity, "from_block_required", "Starting block is required"}

  defp translate_error(:invalid_from_block),
    do: {:unprocessable_entity, "invalid_from_block", "Starting block is invalid"}

  defp translate_error(:invalid_cursor),
    do: {:unprocessable_entity, "invalid_cursor", "Cursor is invalid"}

  defp translate_error(:invalid_limit),
    do: {:unprocessable_entity, "invalid_limit", "Limit is invalid"}

  defp translate_error(:accounting_tags_unavailable),
    do:
      {:bad_gateway, "accounting_tags_unavailable",
       "Payment labels could not be loaded right now"}

  defp translate_error(:invalid_accounting_tag_log),
    do:
      {:bad_gateway, "invalid_accounting_tag_log", "Payment labels could not be loaded right now"}

  defp translate_error(_reason),
    do: {:unprocessable_entity, "subject_invalid", "Subject request could not be completed"}
end
