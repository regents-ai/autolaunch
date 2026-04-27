defmodule AutolaunchWeb.Api.RegentStakingController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Evm
  alias Autolaunch.RegentStaking

  import AutolaunchWeb.Api.ControllerHelpers

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
    render_operator_prepare(conn, fn -> context_module().prepare_deposit_usdc(params) end)
  end

  def prepare_withdraw_treasury(conn, params) do
    render_operator_prepare(conn, fn -> context_module().prepare_withdraw_treasury(params) end)
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

  defp translate_error(reason),
    do: {:unprocessable_entity, "regent_staking_invalid", inspect(reason)}

  defp render_operator_prepare(conn, fun) do
    with_current_human(conn, fn human ->
      if authorized_operator?(human) do
        render_result(conn, fun.())
      else
        render_result(conn, {:error, :operator_required})
      end
    end)
  end

  defp authorized_operator?(human) do
    allowed_wallets = configured_operator_wallets()
    linked_wallets = linked_wallets(human)

    allowed_wallets != [] and Enum.any?(linked_wallets, &(&1 in allowed_wallets))
  end

  defp configured_operator_wallets do
    :autolaunch
    |> Application.get_env(:regent_staking, [])
    |> Keyword.get(:operator_wallets, [])
    |> Enum.map(&Evm.normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp linked_wallets(human) do
    [Map.get(human, :wallet_address) | List.wrap(Map.get(human, :wallet_addresses))]
    |> Enum.map(&Evm.normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp context_module do
    configured_module(:regent_staking_api, :context_module, RegentStaking)
  end
end
