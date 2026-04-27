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

  def translate(:launch_preview, {:agent_not_eligible, agent}) do
    {:unprocessable_entity, "agent_not_eligible", "Agent is not eligible for launch",
     %{agent: agent}}
  end

  def translate(:launch_preview, :agent_not_found),
    do: {:not_found, "agent_not_found", "Agent not found"}

  def translate(:launch_preview, :unauthorized),
    do: {:unauthorized, "auth_required", "Privy session required"}

  def translate(:launch_preview, reason),
    do: {:unprocessable_entity, "launch_preview_invalid", describe(reason)}

  def translate(:launch_create_job, {:agent_not_eligible, agent}) do
    {:unprocessable_entity, "agent_not_eligible", "Agent is not eligible for launch",
     %{agent: agent}}
  end

  def translate(:launch_create_job, :wallet_mismatch) do
    {:forbidden, "wallet_mismatch", "Connected wallet does not match current Privy session"}
  end

  def translate(:launch_create_job, :invalid_chain_id) do
    {:unprocessable_entity, "invalid_chain_id",
     "Chain ID must be Base Sepolia (84532) or Base mainnet (8453)"}
  end

  def translate(:launch_create_job, :invalid_wallet_address) do
    {:unprocessable_entity, "invalid_wallet", "Wallet address is invalid"}
  end

  def translate(:launch_create_job, :message_required) do
    {:unprocessable_entity, "signature_message_required", "SIWA message is required"}
  end

  def translate(:launch_create_job, :signature_required) do
    {:unprocessable_entity, "signature_required", "Wallet signature is required"}
  end

  def translate(:launch_create_job, :nonce_required) do
    {:unprocessable_entity, "nonce_required", "SIWA nonce is required"}
  end

  def translate(:launch_create_job, :unauthorized),
    do: {:unauthorized, "auth_required", "Privy session required"}

  def translate(:launch_create_job, reason),
    do: {:unprocessable_entity, "launch_invalid", describe(reason)}

  def translate(:launch_show_job, :job_not_found),
    do: {:not_found, "job_not_found", "Launch job not found"}

  def translate(:launch_show_job, :not_found),
    do: {:not_found, "job_not_found", "Launch job not found"}

  def translate(:launch_show_job, :forbidden),
    do: {:forbidden, "job_forbidden", "Launch job does not belong to this owner"}

  def translate(:launch_show_job, :job_lookup_failed),
    do: {:internal_server_error, "job_lookup_failed", "Launch job could not be loaded"}

  def translate(:auction_show, :auction_not_found),
    do: {:not_found, "auction_not_found", "Auction not found"}

  def translate(:auction_bid_quote, :auction_not_found),
    do: {:not_found, "auction_not_found", "Auction not found"}

  def translate(:auction_bid_quote, :bid_must_be_above_clearing_price) do
    {:unprocessable_entity, "bid_above_clearing_required",
     "Bid max price must be above the current clearing price"}
  end

  def translate(:auction_bid_quote, :invalid_tick_price) do
    {:unprocessable_entity, "invalid_tick_price",
     "Bid max price must land on a valid auction tick"}
  end

  def translate(:auction_bid_quote, :auction_is_over),
    do: {:unprocessable_entity, "auction_is_over", "Auction is over"}

  def translate(:auction_bid_quote, :auction_not_started),
    do: {:unprocessable_entity, "auction_not_started", "Auction has not started"}

  def translate(:auction_bid_quote, :auction_sold_out),
    do: {:unprocessable_entity, "auction_sold_out", "Auction has sold out"}

  def translate(:auction_bid_quote, reason),
    do: {:unprocessable_entity, "bid_quote_invalid", describe(reason)}

  def translate(:auction_create_bid, :unauthorized),
    do: {:unauthorized, "auth_required", "Privy session required"}

  def translate(:auction_create_bid, :auction_not_found),
    do: {:not_found, "auction_not_found", "Auction not found"}

  def translate(:auction_create_bid, :transaction_pending),
    do: {:accepted, "transaction_pending", "Transaction is still pending confirmation"}

  def translate(:auction_create_bid, :transaction_failed),
    do: {:unprocessable_entity, "transaction_failed", "Transaction failed onchain"}

  def translate(:auction_create_bid, reason),
    do: {:unprocessable_entity, "bid_invalid", describe(reason)}

  def translate(:agentbook, :session_not_found),
    do: {:not_found, "session_not_found", "AgentBook session was not found"}

  def translate(:agentbook, :invalid_agent_address),
    do: {:unprocessable_entity, "invalid_agent_address", "Agent wallet address is invalid"}

  def translate(:agentbook, :invalid_network),
    do: {:unprocessable_entity, "invalid_network", "Network must be world, base, or base-sepolia"}

  def translate(:agentbook, :invalid_request),
    do: {:unprocessable_entity, "invalid_request", "Required request data is missing"}

  def translate(:agentbook, %AgentWorld.Error{message: message}),
    do: {:unprocessable_entity, "agentbook_invalid", message}

  def translate(:agentbook, {:transaction_pending, tx_hash}),
    do: {:accepted, "transaction_pending", "Transaction is still pending", %{tx_hash: tx_hash}}

  def translate(:agentbook, reason),
    do: {:unprocessable_entity, "agentbook_invalid", describe(reason)}

  def translate(:ens_link, :unauthorized),
    do: {:unauthorized, "auth_required", "Privy session required"}

  def translate(:ens_link, :agent_not_found),
    do: {:not_found, "agent_not_found", "ERC-8004 identity not found"}

  def translate(:ens_link, :identity_registry_not_configured),
    do:
      {:unprocessable_entity, "identity_registry_not_configured",
       "ERC-8004 registry is not configured for this chain"}

  def translate(:ens_link, :rpc_not_configured),
    do: {:unprocessable_entity, "rpc_not_configured", "RPC URL is not configured for this chain"}

  def translate(:ens_link, :signer_not_linked),
    do:
      {:unprocessable_entity, "signer_not_linked",
       "Signer must be one of the wallets linked to the current session"}

  def translate(:ens_link, :invalid_chain_id),
    do: {:unprocessable_entity, "invalid_chain_id", "Invalid chain id"}

  def translate(:ens_link, :invalid_agent_id),
    do: {:unprocessable_entity, "invalid_agent_id", "Invalid agent id"}

  def translate(:ens_link, :ens_name_required),
    do: {:unprocessable_entity, "ens_name_required", "ENS name is required"}

  def translate(:ens_link, %AgentEns.Error{message: message}),
    do: {:unprocessable_entity, "ens_link_invalid", message}

  def translate(:ens_link, reason),
    do: {:unprocessable_entity, "ens_link_invalid", describe(reason)}

  def translate(action, :unauthorized) when action in [:bid_exit, :bid_return, :bid_claim],
    do: {:unauthorized, "auth_required", "Privy session required"}

  def translate(action, :forbidden) when action in [:bid_exit, :bid_return, :bid_claim],
    do: {:forbidden, "bid_forbidden", "Bid does not belong to this operator"}

  def translate(action, :not_found) when action in [:bid_exit, :bid_return, :bid_claim],
    do: {:not_found, "bid_not_found", "Bid not found"}

  def translate(action, :transaction_pending)
      when action in [:bid_exit, :bid_return, :bid_claim],
      do: {:accepted, "transaction_pending", "Transaction is still pending confirmation"}

  def translate(action, :transaction_failed) when action in [:bid_exit, :bid_return, :bid_claim],
    do: {:unprocessable_entity, "transaction_failed", "Transaction failed onchain"}

  def translate(:bid_exit, reason),
    do: {:unprocessable_entity, "bid_exit_invalid", describe(reason)}

  def translate(:bid_return, reason),
    do: {:unprocessable_entity, "bid_return_invalid", describe(reason)}

  def translate(:bid_claim, reason),
    do: {:unprocessable_entity, "bid_claim_invalid", describe(reason)}

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)
end
