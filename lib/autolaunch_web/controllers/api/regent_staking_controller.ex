defmodule AutolaunchWeb.Api.RegentStakingController do
  use AutolaunchWeb, :controller

  alias Autolaunch.RegentStaking
  alias AutolaunchWeb.RegentStakingAccess

  import AutolaunchWeb.Api.ControllerHelpers

  def show(conn, _params) do
    render_result(conn, context_module().overview(staking_actor(conn)))
  end

  def account(conn, %{"address" => address}) do
    render_result(conn, context_module().account(address, staking_actor(conn)))
  end

  def stake(conn, params) do
    render_result(conn, context_module().stake(params, staking_actor(conn)))
  end

  def unstake(conn, params) do
    render_result(conn, context_module().unstake(params, staking_actor(conn)))
  end

  def claim_usdc(conn, params) do
    render_result(conn, context_module().claim_usdc(params, staking_actor(conn)))
  end

  def claim_regent(conn, params) do
    render_result(conn, context_module().claim_regent(params, staking_actor(conn)))
  end

  def claim_and_restake_regent(conn, params) do
    render_result(
      conn,
      context_module().claim_and_restake_regent(params, staking_actor(conn))
    )
  end

  def prepare_deposit(conn, params) do
    render_operator_prepare(conn, fn operator_wallet_address ->
      context_module().prepare_deposit_usdc(params, operator_wallet_address)
    end)
  end

  def prepare_withdraw_treasury(conn, params) do
    render_operator_prepare(conn, fn operator_wallet_address ->
      context_module().prepare_withdraw_treasury(params, operator_wallet_address)
    end)
  end

  defp render_result(conn, result), do: render_api_result(conn, result, &translate_error/1)

  defp translate_error(:unauthorized),
    do: {:unauthorized, "auth_required", "Privy session required"}

  defp translate_error(:operator_required),
    do: {:forbidden, "operator_required", "Use an authorized operator wallet"}

  defp translate_error(:unconfigured),
    do:
      {:service_unavailable, "regent_staking_unavailable",
       "Regent staking is not configured on this backend"}

  defp translate_error(:invalid_address),
    do: {:unprocessable_entity, "invalid_address", "Address is invalid"}

  defp translate_error(:invalid_ens_name),
    do: {:unprocessable_entity, "invalid_ens_name", "ENS name is invalid"}

  defp translate_error(:ens_address_missing),
    do: {:unprocessable_entity, "ens_address_missing", "ENS name does not point to a wallet"}

  defp translate_error(:ens_unconfigured),
    do: {:service_unavailable, "ens_unavailable", "ENS lookup is unavailable right now"}

  defp translate_error(:ens_unavailable),
    do: {:service_unavailable, "ens_unavailable", "ENS lookup is unavailable right now"}

  defp translate_error(:amount_required),
    do: {:unprocessable_entity, "amount_required", "Amount is required"}

  defp translate_error(:invalid_amount_precision),
    do: {:unprocessable_entity, "invalid_amount_precision", "Amount precision is too high"}

  defp translate_error(:source_tag_required),
    do: {:unprocessable_entity, "source_tag_required", "Source tag is required"}

  defp translate_error(:source_ref_required),
    do: {:unprocessable_entity, "source_ref_required", "Source reference is required"}

  defp translate_error(:invalid_source_ref),
    do:
      {:unprocessable_entity, "invalid_source_ref",
       "Source tag or source reference must be bytes32 hex or 32 bytes of text"}

  defp translate_error(_reason),
    do:
      {:unprocessable_entity, "regent_staking_invalid",
       "Regent staking request could not be completed"}

  defp render_operator_prepare(conn, fun) do
    with_current_human(conn, fn human ->
      case RegentStakingAccess.authorized_operator_wallet(human) do
        {:ok, operator_wallet_address} -> render_result(conn, fun.(operator_wallet_address))
        {:error, :operator_required} -> render_result(conn, {:error, :operator_required})
      end
    end)
  end

  defp context_module do
    configured_module(:regent_staking_api, :context_module, RegentStaking)
  end

  defp staking_actor(%{assigns: %{current_human: current_human}})
       when not is_nil(current_human),
       do: current_human

  defp staking_actor(%{assigns: %{current_agent_claims: claims}}) when is_map(claims), do: claims
  defp staking_actor(_conn), do: nil
end
