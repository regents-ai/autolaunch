defmodule AutolaunchWeb.Api.SwapController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Swaps

  import AutolaunchWeb.Api.ControllerHelpers

  def quote(conn, params) do
    with_current_human(conn, fn current_human ->
      render_result(conn, swaps_module().quote(params, current_human))
    end)
  end

  def prepare(conn, params) do
    with_current_human(conn, fn current_human ->
      render_result(conn, swaps_module().prepare(params, current_human))
    end)
  end

  defp render_result(conn, result), do: render_api_result(conn, result, &translate_error/1)

  defp translate_error(:unauthorized),
    do: {:unauthorized, "auth_required", "Connect wallet first"}

  defp translate_error(:swaps_disabled),
    do: {:unprocessable_entity, "swaps_disabled", "Swaps are not available yet"}

  defp translate_error(:swaps_unconfigured),
    do: {:unprocessable_entity, "swaps_unconfigured", "Swaps are not available yet"}

  defp translate_error(:unsupported_chain),
    do: {:unprocessable_entity, "unsupported_chain", "Use Base for this swap"}

  defp translate_error(:token_not_found),
    do: {:unprocessable_entity, "token_not_found", "This token is not available for in-app swaps"}

  defp translate_error(:invalid_side),
    do: {:unprocessable_entity, "invalid_side", "Choose buy or sell"}

  defp translate_error(:invalid_amount),
    do: {:unprocessable_entity, "invalid_amount", "Enter a valid amount"}

  defp translate_error(:invalid_slippage),
    do: {:unprocessable_entity, "invalid_slippage", "Choose a valid slippage limit"}

  defp translate_error(:invalid_address),
    do: {:unprocessable_entity, "invalid_address", "Wallet or token address is invalid"}

  defp translate_error(:wallet_mismatch),
    do: {:unauthorized, "wallet_mismatch", "Use the connected wallet for this swap"}

  defp translate_error(:unsupported_route),
    do: {:unprocessable_entity, "unsupported_route", "No Uniswap v4 route is available right now"}

  defp translate_error(:invalid_swap_transaction),
    do: {:unprocessable_entity, "swap_unavailable", "Swap transaction is not available"}

  defp translate_error(:invalid_approval_transaction),
    do: {:unprocessable_entity, "swap_unavailable", "Swap approval is not available"}

  defp translate_error(:price_impact_too_high),
    do: {:unprocessable_entity, "price_impact_too_high", "Price impact is too high right now"}

  defp translate_error(:price_impact_unavailable),
    do: {:unprocessable_entity, "price_impact_unavailable", "Price impact is not available"}

  defp translate_error({:uniswap_error, _status, _code, detail}),
    do: {:unprocessable_entity, "uniswap_unavailable", detail || "Swap quote is not available"}

  defp translate_error({:uniswap_transport, _reason}),
    do: {:unprocessable_entity, "uniswap_unavailable", "Swap quote is not available"}

  defp translate_error(_reason),
    do: {:unprocessable_entity, "swap_unavailable", "Swap is not available"}

  defp swaps_module do
    configured_module(:swap_controller, :swaps_module, Swaps)
  end
end
