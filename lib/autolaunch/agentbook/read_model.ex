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
      tx_request: session.tx_request,
      frontend_request: %{
        app_id: session.app_id,
        action: session.action,
        rp_context: session.rp_context,
        signal: session.signal
      }
    }
  end

  def tx_request(nil), do: nil

  def tx_request(%AgentWorld.TxRequest{} = request) do
    %{
      to: request.to,
      data: request.data,
      value: request.value,
      chain_id: request.chain_id,
      description: request.description
    }
  end

  def tx_request(value) when is_map(value), do: value
end
