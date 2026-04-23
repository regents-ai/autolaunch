defmodule AutolaunchWeb.Api.SubjectController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Revenue
  alias AutolaunchWeb.ApiError
  alias AutolaunchWeb.LiveUpdates

  def show(conn, %{"id" => subject_id}) do
    case Revenue.subject_state(subject_id, conn.assigns[:current_human]) do
      {:ok, subject_state} ->
        json(conn, Map.put(subject_state, :ok, true))

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def ingress(conn, %{"id" => subject_id}) do
    case Revenue.ingress_state(subject_id, conn.assigns[:current_human]) do
      {:ok, ingress_state} ->
        json(conn, Map.put(ingress_state, :ok, true))

      {:error, reason} ->
        render_error(conn, reason)
    end
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
    json(conn, Map.put(payload, :ok, true))
  end

  defp render_write(conn, {:error, reason}), do: render_error(conn, reason)

  defp render_error(conn, :unauthorized),
    do: ApiError.render(conn, :unauthorized, "auth_required", "Connect a wallet first")

  defp render_error(conn, :not_found),
    do: ApiError.render(conn, :not_found, "subject_not_found", "Token page not found")

  defp render_error(conn, :subject_lookup_failed),
    do:
      ApiError.render(
        conn,
        :internal_server_error,
        "subject_lookup_failed",
        "Token details could not be loaded"
      )

  defp render_error(conn, :forbidden),
    do: ApiError.render(conn, :forbidden, "subject_forbidden", "Use the connected wallet")

  defp render_error(conn, :transaction_pending),
    do:
      ApiError.render(
        conn,
        :accepted,
        "transaction_pending",
        "Transaction is still pending confirmation"
      )

  defp render_error(conn, :transaction_failed),
    do:
      ApiError.render(
        conn,
        :unprocessable_entity,
        "transaction_failed",
        "The wallet action failed"
      )

  defp render_error(conn, :transaction_target_mismatch),
    do:
      ApiError.render(
        conn,
        :forbidden,
        "transaction_target_mismatch",
        "This wallet action is for a different token"
      )

  defp render_error(conn, :transaction_hash_reused),
    do:
      ApiError.render(
        conn,
        :conflict,
        "transaction_hash_reused",
        "Transaction hash has already been registered"
      )

  defp render_error(conn, :transaction_data_mismatch),
    do:
      ApiError.render(
        conn,
        :unprocessable_entity,
        "transaction_data_mismatch",
        "This wallet action does not match the selected action"
      )

  defp render_error(conn, :invalid_transaction_hash),
    do:
      ApiError.render(
        conn,
        :unprocessable_entity,
        "invalid_transaction_hash",
        "Transaction hash is invalid"
      )

  defp render_error(conn, :invalid_subject_id),
    do:
      ApiError.render(conn, :unprocessable_entity, "invalid_subject_id", "Token page is invalid")

  defp render_error(conn, :invalid_amount),
    do: ApiError.render(conn, :unprocessable_entity, "invalid_amount", "Amount is invalid")

  defp render_error(conn, :invalid_amount_precision),
    do:
      ApiError.render(
        conn,
        :unprocessable_entity,
        "invalid_amount_precision",
        "Amount precision is too high"
      )

  defp render_error(conn, :amount_required),
    do: ApiError.render(conn, :unprocessable_entity, "amount_required", "Amount is required")

  defp render_error(conn, :invalid_ingress_address),
    do:
      ApiError.render(
        conn,
        :unprocessable_entity,
        "invalid_ingress_address",
        "USDC intake address is invalid"
      )

  defp render_error(conn, :ingress_not_found),
    do:
      ApiError.render(
        conn,
        :not_found,
        "ingress_not_found",
        "USDC intake address does not belong to this token"
      )

  defp render_error(conn, :invalid_source_ref),
    do:
      ApiError.render(
        conn,
        :unprocessable_entity,
        "invalid_source_ref",
        "Source reference is invalid"
      )

  defp render_error(conn, reason),
    do: ApiError.render(conn, :unprocessable_entity, "subject_invalid", inspect(reason))
end
