defmodule AutolaunchWeb.Api.RegentStakingController do
  use AutolaunchWeb, :controller

  alias Autolaunch.RegentStaking
  alias AutolaunchWeb.ApiError

  def show(conn, _params) do
    render_result(conn, context_module().overview(conn.assigns[:current_human]))
  end

  def account(conn, %{"address" => address}) do
    render_result(conn, context_module().account(address, conn.assigns[:current_human]))
  end

  def stake(conn, params) do
    render_result(conn, context_module().stake(params, conn.assigns[:current_human]))
  end

  def unstake(conn, params) do
    render_result(conn, context_module().unstake(params, conn.assigns[:current_human]))
  end

  def claim_usdc(conn, params) do
    render_result(conn, context_module().claim_usdc(params, conn.assigns[:current_human]))
  end

  def claim_regent(conn, params) do
    render_result(conn, context_module().claim_regent(params, conn.assigns[:current_human]))
  end

  def claim_and_restake_regent(conn, params) do
    render_result(
      conn,
      context_module().claim_and_restake_regent(params, conn.assigns[:current_human])
    )
  end

  def prepare_deposit(conn, params) do
    render_result(conn, context_module().prepare_deposit_usdc(params))
  end

  def prepare_withdraw_treasury(conn, params) do
    render_result(conn, context_module().prepare_withdraw_treasury(params))
  end

  defp render_result(conn, {:ok, payload}), do: json(conn, Map.put(payload, :ok, true))

  defp render_result(conn, {:error, :unauthorized}) do
    ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")
  end

  defp render_result(conn, {:error, :unconfigured}) do
    ApiError.render(
      conn,
      :service_unavailable,
      "regent_staking_unavailable",
      "Regent staking is not configured on this backend"
    )
  end

  defp render_result(conn, {:error, :invalid_address}) do
    ApiError.render(conn, :unprocessable_entity, "invalid_address", "Address is invalid")
  end

  defp render_result(conn, {:error, :amount_required}) do
    ApiError.render(conn, :unprocessable_entity, "amount_required", "Amount is required")
  end

  defp render_result(conn, {:error, :invalid_amount_precision}) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "invalid_amount_precision",
      "Amount precision is too high"
    )
  end

  defp render_result(conn, {:error, :source_tag_required}) do
    ApiError.render(conn, :unprocessable_entity, "source_tag_required", "Source tag is required")
  end

  defp render_result(conn, {:error, :source_ref_required}) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "source_ref_required",
      "Source reference is required"
    )
  end

  defp render_result(conn, {:error, :invalid_source_ref}) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "invalid_source_ref",
      "Source tag or source reference must be bytes32 hex or 32 bytes of text"
    )
  end

  defp render_result(conn, {:error, reason}) do
    ApiError.render(conn, :unprocessable_entity, "regent_staking_invalid", inspect(reason))
  end

  defp context_module do
    Application.get_env(:autolaunch, :regent_staking_api, [])
    |> Keyword.get(:context_module, RegentStaking)
  end
end
