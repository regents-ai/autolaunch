defmodule AutolaunchWeb.ApiErrorTranslator do
  @moduledoc false

  alias AutolaunchWeb.ApiError

  def render(conn, _context, {:sidecar_error, status, body}) do
    conn
    |> Plug.Conn.put_status(status)
    |> Phoenix.Controller.json(body)
  end

  def render(conn, _context, {:verify_failed, response}) do
    conn
    |> Plug.Conn.put_status(:unauthorized)
    |> Phoenix.Controller.json(response)
  end

  def render(conn, context, reason) do
    case translate(context, reason) do
      {status, code, message} ->
        ApiError.render(conn, status, code, message)

      {status, code, message, meta} ->
        ApiError.render(conn, status, code, message, meta)
    end
  end

  defp translate(:launch_preview, {:agent_not_eligible, agent}) do
    {:unprocessable_entity, "agent_not_eligible", "Agent is not eligible for launch",
     %{agent: agent}}
  end

  defp translate(:launch_preview, :agent_not_found),
    do: {:not_found, "agent_not_found", "Agent not found"}

  defp translate(:launch_preview, :unauthorized),
    do: {:unauthorized, "auth_required", "Privy session required"}

  defp translate(:launch_preview, reason),
    do: {:unprocessable_entity, "launch_preview_invalid", describe(reason)}

  defp translate(:launch_create_job, {:agent_not_eligible, agent}) do
    {:unprocessable_entity, "agent_not_eligible", "Agent is not eligible for launch",
     %{agent: agent}}
  end

  defp translate(:launch_create_job, :wallet_mismatch) do
    {:forbidden, "wallet_mismatch", "Connected wallet does not match current Privy session"}
  end

  defp translate(:launch_create_job, :invalid_chain_id) do
    {:unprocessable_entity, "invalid_chain_id",
     "Chain ID must be Base Sepolia (84532) or Base mainnet (8453)"}
  end

  defp translate(:launch_create_job, :invalid_wallet_address) do
    {:unprocessable_entity, "invalid_wallet", "Wallet address is invalid"}
  end

  defp translate(:launch_create_job, :message_required) do
    {:unprocessable_entity, "signature_message_required", "SIWA message is required"}
  end

  defp translate(:launch_create_job, :signature_required) do
    {:unprocessable_entity, "signature_required", "Wallet signature is required"}
  end

  defp translate(:launch_create_job, :nonce_required) do
    {:unprocessable_entity, "nonce_required", "SIWA nonce is required"}
  end

  defp translate(:launch_create_job, :unauthorized),
    do: {:unauthorized, "auth_required", "Privy session required"}

  defp translate(:launch_create_job, reason),
    do: {:unprocessable_entity, "launch_invalid", describe(reason)}

  defp translate(:launch_show_job, :job_not_found),
    do: {:not_found, "job_not_found", "Launch job not found"}

  defp translate(:launch_show_job, :not_found),
    do: {:not_found, "job_not_found", "Launch job not found"}

  defp translate(:launch_show_job, :forbidden),
    do: {:forbidden, "job_forbidden", "Launch job does not belong to this owner"}

  defp translate(:launch_show_job, :job_lookup_failed),
    do: {:internal_server_error, "job_lookup_failed", "Launch job could not be loaded"}

  defp translate(:auction_show, :auction_not_found),
    do: {:not_found, "auction_not_found", "Auction not found"}

  defp translate(:auction_bid_quote, :auction_not_found),
    do: {:not_found, "auction_not_found", "Auction not found"}

  defp translate(:auction_bid_quote, :bid_must_be_above_clearing_price) do
    {:unprocessable_entity, "bid_above_clearing_required",
     "Bid max price must be above the current clearing price"}
  end

  defp translate(:auction_bid_quote, :invalid_tick_price) do
    {:unprocessable_entity, "invalid_tick_price",
     "Bid max price must land on a valid auction tick"}
  end

  defp translate(:auction_bid_quote, :auction_is_over),
    do: {:unprocessable_entity, "auction_is_over", "Auction is over"}

  defp translate(:auction_bid_quote, :auction_not_started),
    do: {:unprocessable_entity, "auction_not_started", "Auction has not started"}

  defp translate(:auction_bid_quote, :auction_sold_out),
    do: {:unprocessable_entity, "auction_sold_out", "Auction has sold out"}

  defp translate(:auction_bid_quote, reason),
    do: {:unprocessable_entity, "bid_quote_invalid", describe(reason)}

  defp translate(:auction_create_bid, :unauthorized),
    do: {:unauthorized, "auth_required", "Privy session required"}

  defp translate(:auction_create_bid, :auction_not_found),
    do: {:not_found, "auction_not_found", "Auction not found"}

  defp translate(:auction_create_bid, :transaction_pending),
    do: {:accepted, "transaction_pending", "Transaction is still pending confirmation"}

  defp translate(:auction_create_bid, :transaction_failed),
    do: {:unprocessable_entity, "transaction_failed", "Transaction failed onchain"}

  defp translate(:auction_create_bid, reason),
    do: {:unprocessable_entity, "bid_invalid", describe(reason)}

  defp translate(action, :unauthorized) when action in [:bid_exit, :bid_return, :bid_claim],
    do: {:unauthorized, "auth_required", "Privy session required"}

  defp translate(action, :forbidden) when action in [:bid_exit, :bid_return, :bid_claim],
    do: {:forbidden, "bid_forbidden", "Bid does not belong to this operator"}

  defp translate(action, :not_found) when action in [:bid_exit, :bid_return, :bid_claim],
    do: {:not_found, "bid_not_found", "Bid not found"}

  defp translate(action, :transaction_pending)
       when action in [:bid_exit, :bid_return, :bid_claim],
       do: {:accepted, "transaction_pending", "Transaction is still pending confirmation"}

  defp translate(action, :transaction_failed) when action in [:bid_exit, :bid_return, :bid_claim],
    do: {:unprocessable_entity, "transaction_failed", "Transaction failed onchain"}

  defp translate(:bid_exit, reason),
    do: {:unprocessable_entity, "bid_exit_invalid", describe(reason)}

  defp translate(:bid_return, reason),
    do: {:unprocessable_entity, "bid_return_invalid", describe(reason)}

  defp translate(:bid_claim, reason),
    do: {:unprocessable_entity, "bid_claim_invalid", describe(reason)}

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)
end
