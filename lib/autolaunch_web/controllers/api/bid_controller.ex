defmodule AutolaunchWeb.Api.BidController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias AutolaunchWeb.ApiError

  def exit(conn, %{"id" => id} = params) do
    case launch_module().exit_bid(id, params, conn.assigns[:current_human]) do
      {:ok, position} ->
        json(conn, %{ok: true, bid: position})

      {:error, :unauthorized} ->
        ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")

      {:error, :forbidden} ->
        ApiError.render(conn, :forbidden, "bid_forbidden", "Bid does not belong to this operator")

      {:error, :not_found} ->
        ApiError.render(conn, :not_found, "bid_not_found", "Bid not found")

      {:error, :transaction_pending} ->
        ApiError.render(
          conn,
          :accepted,
          "transaction_pending",
          "Transaction is still pending confirmation"
        )

      {:error, :transaction_failed} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "transaction_failed",
          "Transaction failed onchain"
        )

      {:error, reason} ->
        ApiError.render(conn, :unprocessable_entity, "bid_exit_invalid", inspect(reason))
    end
  end

  def claim(conn, %{"id" => id} = params) do
    case launch_module().claim_bid(id, params, conn.assigns[:current_human]) do
      {:ok, position} ->
        json(conn, %{ok: true, bid: position})

      {:error, :unauthorized} ->
        ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")

      {:error, :forbidden} ->
        ApiError.render(conn, :forbidden, "bid_forbidden", "Bid does not belong to this operator")

      {:error, :not_found} ->
        ApiError.render(conn, :not_found, "bid_not_found", "Bid not found")

      {:error, :transaction_pending} ->
        ApiError.render(
          conn,
          :accepted,
          "transaction_pending",
          "Transaction is still pending confirmation"
        )

      {:error, :transaction_failed} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "transaction_failed",
          "Transaction failed onchain"
        )

      {:error, reason} ->
        ApiError.render(conn, :unprocessable_entity, "bid_claim_invalid", inspect(reason))
    end
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:bid_controller, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
