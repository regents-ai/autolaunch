defmodule Autolaunch.Agentbook.ReadModel do
  @moduledoc false

  alias Autolaunch.Agentbook.Session

  def session(%Session{} = session) do
    %{
      session_id: session.session_id,
      launch_job_id: session.launch_job_id,
      status: session.status,
      agent_address: session.agent_address,
      network: session.network,
      chain_id: session.chain_id,
      contract_address: session.contract_address,
      nonce: session.nonce,
      relay_url: session.relay_url,
      connector_uri: session.connector_uri,
      deep_link_uri: session.deep_link_uri,
      tx_hash: session.tx_hash,
      human_id: session.human_id,
      error_text: session.error_text,
      expires_at: session.expires_at && DateTime.to_iso8601(session.expires_at),
      proof_payload: session.proof_payload,
      wallet_action: wallet_action(session.tx_request, session.session_id, session.agent_address),
      frontend_request: %{
        app_id: session.app_id,
        action: session.action,
        rp_context: session.rp_context,
        signal: session.signal
      }
    }
  end

  def wallet_action(nil, _resource_id, _agent_address), do: nil

  def wallet_action(%AgentWorld.TxRequest{} = request, resource_id, agent_address) do
    expected_signer = request.expected_signer || agent_address
    idempotency_key = request.idempotency_key || "agentbook:#{resource_id}"

    risk_copy =
      request.risk_copy || request.description || "Review the wallet action before signing."

    %{
      action_id: idempotency_key,
      owner_product: "autolaunch",
      resource: "agentbook",
      resource_id: resource_id,
      action: "register_agentbook_proof",
      to: request.to,
      data: request.data,
      value: hex_value!(request.value),
      chain_id: request.chain_id,
      expected_signer: expected_signer,
      expires_at: request.expires_at,
      idempotency_key: idempotency_key,
      simulation: %{required: false, status: "not_required", block_number: nil},
      risk_copy: risk_copy
    }
  end

  def wallet_action(%{"owner_product" => "autolaunch"} = action, _resource_id, _agent_address),
    do: action

  def wallet_action(%{owner_product: "autolaunch"} = action, _resource_id, _agent_address),
    do: action

  defp hex_value!(nil), do: "0x0"

  defp hex_value!(value) when is_binary(value) do
    value = String.trim(value)

    with "0x" <> hex <- value,
         true <- Regex.match?(~r/\A[0-9a-fA-F]+\z/, hex) do
      "0x" <> (hex |> String.to_integer(16) |> Integer.to_string(16))
    else
      _ -> raise ArgumentError, "invalid wallet action value"
    end
  end

  defp hex_value!(_value), do: raise(ArgumentError, "invalid wallet action value")
end
