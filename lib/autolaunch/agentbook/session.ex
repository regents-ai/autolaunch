defmodule Autolaunch.Agentbook.Session do
  @moduledoc false
  use Autolaunch.Schema

  @primary_key {:session_id, :string, autogenerate: false}

  schema "autolaunch_agentbook_sessions" do
    field :launch_job_id, :string
    field :agent_address, :string
    field :network, :string
    field :chain_id, :integer
    field :contract_address, :string
    field :relay_url, :string
    field :nonce, :integer
    field :app_id, :string
    field :action, :string
    field :rp_id, :string
    field :signal, :string
    field :rp_context, :map
    field :connector_uri, :string
    field :deep_link_uri, :string
    field :proof_payload, :map
    field :tx_request, :map
    field :status, :string, default: "pending"
    field :tx_hash, :string
    field :human_id, :string
    field :error_text, :string
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :session_id,
      :launch_job_id,
      :agent_address,
      :network,
      :chain_id,
      :contract_address,
      :relay_url,
      :nonce,
      :app_id,
      :action,
      :rp_id,
      :signal,
      :rp_context,
      :connector_uri,
      :deep_link_uri,
      :proof_payload,
      :tx_request,
      :status,
      :tx_hash,
      :human_id,
      :error_text,
      :expires_at
    ])
    |> validate_required([
      :session_id,
      :agent_address,
      :network,
      :chain_id,
      :contract_address,
      :nonce,
      :app_id,
      :action,
      :rp_id,
      :signal,
      :rp_context,
      :status,
      :expires_at
    ])
  end

  def update_changeset(session, attrs) do
    cast(session, attrs, [
      :connector_uri,
      :deep_link_uri,
      :proof_payload,
      :tx_request,
      :status,
      :tx_hash,
      :human_id,
      :error_text
    ])
  end
end
