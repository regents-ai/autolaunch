defmodule Autolaunch.Agentbook do
  @moduledoc false

  import Ecto.Query, warn: false

  alias AgentWorld.Error
  alias Autolaunch.Agentbook.ReadModel
  alias Autolaunch.Agentbook.Session
  alias Autolaunch.Launch
  alias Autolaunch.Repo

  def create_session(attrs) when is_map(attrs) do
    with {:ok, created} <- registration_module().create_session(attrs),
         {:ok, created} <- normalize_created_session(created, attrs),
         {:ok, session} <- persist_created_session(created) do
      {:ok, ReadModel.session(session)}
    end
  end

  def get_session(session_id) when is_binary(session_id) do
    case Repo.get(Session, session_id) do
      nil -> nil
      session -> ReadModel.session(session)
    end
  end

  def submit_session(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    with %Session{} = session <- Repo.get(Session, session_id),
         {:ok, updated} <- submit_session_payload(session, attrs),
         {:ok, persisted} <- persist_updated_session(session, updated) do
      {:ok, ReadModel.session(persisted)}
    else
      nil -> {:error, :session_not_found}
      {:error, _} = error -> error
    end
  end

  def store_connector_uri(session_id, connector_uri)
      when is_binary(session_id) and is_binary(connector_uri) do
    with %Session{} = session <- Repo.get(Session, session_id),
         {:ok, updated} <-
           session
           |> Session.update_changeset(%{
             connector_uri: connector_uri,
             deep_link_uri: connector_uri
           })
           |> Repo.update() do
      {:ok, ReadModel.session(updated)}
    else
      nil -> {:error, :session_not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def fail_session(session_id, message) when is_binary(session_id) do
    with %Session{} = session <- Repo.get(Session, session_id),
         {:ok, updated} <-
           session
           |> Session.update_changeset(%{status: "failed", error_text: to_string(message)})
           |> Repo.update() do
      {:ok, ReadModel.session(updated)}
    else
      nil -> {:error, :session_not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def lookup_human(attrs) when is_map(attrs) do
    with {:ok, agent_address} <-
           required_address(Map.get(attrs, "agent_address")),
         {:ok, network} <- required_network(Map.get(attrs, "network")),
         {:ok, network_config} <- agent_book_module().resolve_network(network, attrs),
         {:ok, human_id} <- agent_book_module().lookup_human(agent_address, network, attrs) do
      {:ok,
       %{
         registered: not is_nil(human_id),
         human_id: human_id,
         agent_address: String.downcase(agent_address),
         network: network_config.id,
         chain_id: network_config.chain_id,
         contract_address: network_config.contract_address
       }}
    end
  end

  def verify_header(attrs) when is_map(attrs) do
    with {:ok, header} <-
           required_text(Map.get(attrs, "header"), :header_required),
         {:ok, resource_uri} <-
           required_text(Map.get(attrs, "resource_uri"), :resource_uri_required),
         {:ok, payload} <- AgentWorld.parse_agentkit_header(header),
         {:ok, _valid} <- AgentWorld.validate_agentkit_message(payload, resource_uri, %{}),
         {:ok, verified} <- AgentWorld.verify_agentkit_signature(payload, %{}) do
      {:ok,
       %{
         valid: true,
         payload: payload,
         recovered_address: verified.address
       }}
    end
  end

  def list_recent_sessions(limit \\ 8) do
    Repo.all(from session in Session, order_by: [desc: session.inserted_at], limit: ^limit)
    |> Enum.map(&ReadModel.session/1)
  end

  defp persist_created_session(created) do
    %Session{}
    |> Session.create_changeset(%{
      session_id: created.session_id,
      launch_job_id: Map.get(created, :launch_job_id),
      agent_address: created.agent_address,
      network: created.network,
      chain_id: created.chain_id,
      contract_address: created.contract_address,
      relay_url: created.relay_url,
      nonce: created.nonce,
      app_id: created.app_id,
      action: created.action,
      rp_id: created.rp_id,
      signal: created.signal,
      rp_context: created.rp_context,
      connector_uri: created.connector_uri,
      deep_link_uri: created.deep_link_uri,
      proof_payload: created.proof_payload,
      tx_request: ReadModel.tx_request(created.tx_request),
      status: status_string(created.status),
      tx_hash: created.tx_hash,
      human_id: created.human_id,
      error_text: created.error_text,
      expires_at: created.expires_at
    })
    |> Repo.insert()
  end

  defp submit_session_payload(session, %{"tx_hash" => tx_hash})
       when is_binary(tx_hash) and tx_hash != "" do
    registration_module().register_transaction(tx_hash, to_world_session(session))
  end

  defp submit_session_payload(session, attrs) do
    proof_payload = Map.get(attrs, "proof") || attrs
    options = %{submission: submission_mode(attrs)}

    case registration_module().submit_proof(to_world_session(session), proof_payload, options) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Error{} = error} ->
        session
        |> Session.update_changeset(%{status: "failed", error_text: Exception.message(error)})
        |> Repo.update()

        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp submission_mode(attrs) do
    if Map.get(attrs, "submission") == "manual", do: :manual, else: :auto
  end

  defp persist_updated_session(session, updated) do
    updated = normalize_updated_session(updated)

    session
    |> Session.update_changeset(%{
      status: status_string(updated.status),
      proof_payload: updated.proof_payload || session.proof_payload,
      tx_request: ReadModel.tx_request(updated.tx_request) || session.tx_request,
      tx_hash: updated.tx_hash || session.tx_hash,
      human_id: updated.human_id || session.human_id,
      error_text: updated.error_text,
      connector_uri: session.connector_uri,
      deep_link_uri: session.deep_link_uri
    })
    |> Repo.update()
    |> maybe_attach_human_identity()
  end

  defp to_world_session(%Session{} = session) do
    %{
      session_id: session.session_id,
      launch_job_id: session.launch_job_id,
      status: status_atom(session.status),
      agent_address: session.agent_address,
      network: session.network,
      chain_id: session.chain_id,
      contract_address: session.contract_address,
      relay_url: session.relay_url,
      nonce: session.nonce,
      app_id: session.app_id,
      action: session.action,
      rp_id: session.rp_id,
      signal: session.signal,
      rp_context: session.rp_context,
      connector_uri: session.connector_uri,
      deep_link_uri: session.deep_link_uri,
      expires_at: session.expires_at,
      proof_payload: session.proof_payload,
      tx_request: session.tx_request,
      tx_hash: session.tx_hash,
      human_id: session.human_id,
      error_text: session.error_text
    }
  end

  defp status_string(value) when is_atom(value), do: Atom.to_string(value)
  defp status_string(value) when is_binary(value), do: value
  defp status_string(_value), do: "failed"

  defp status_atom(value) when is_binary(value) do
    case value do
      "pending" -> :pending
      "proof_ready" -> :proof_ready
      "registered" -> :registered
      "failed" -> :failed
      _ -> :pending
    end
  end

  defp maybe_attach_human_identity({:ok, %Session{status: "registered"} = session}) do
    case agent_book_module().lookup_human(session.agent_address, session.network, %{}) do
      {:ok, human_id} when is_binary(human_id) and human_id != "" ->
        {:ok, updated_session} = maybe_store_human_id(session, human_id)
        maybe_record_launch_completion(updated_session, human_id)
        {:ok, updated_session}

      _ ->
        {:ok, session}
    end
  end

  defp maybe_attach_human_identity(result), do: result

  defp maybe_store_human_id(%Session{human_id: human_id} = session, human_id), do: {:ok, session}

  defp maybe_store_human_id(%Session{} = session, human_id) do
    session
    |> Session.update_changeset(%{human_id: human_id})
    |> Repo.update()
  end

  defp maybe_record_launch_completion(%Session{launch_job_id: launch_job_id} = session, human_id)
       when is_binary(launch_job_id) and launch_job_id != "" do
    _ =
      Launch.record_world_agentbook_completion(launch_job_id, %{
        human_id: human_id,
        agent_address: session.agent_address,
        network: session.network
      })

    :ok
  end

  defp maybe_record_launch_completion(_session, _human_id), do: :ok

  defp required_address(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_agent_address}
    end
  end

  defp required_address(_value), do: {:error, :invalid_agent_address}

  defp required_network(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed in ["world", "base", "base-sepolia"],
      do: {:ok, trimmed},
      else: {:error, :invalid_network}
  end

  defp required_network(_value), do: {:error, :invalid_network}

  defp required_text(value, _reason) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_request}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_text(_value, _reason), do: {:error, :invalid_request}

  defp registration_module do
    Application.get_env(:autolaunch, :agentbook, [])
    |> Keyword.get(:registration_module, AgentWorld.Registration)
  end

  defp agent_book_module do
    Application.get_env(:autolaunch, :agentbook, [])
    |> Keyword.get(:agent_book_module, AgentWorld.AgentBook)
  end

  defp normalize_created_session(created, attrs) when is_map(created) and is_map(attrs) do
    with {:ok, session_id} <- fetch_required(created, :session_id),
         {:ok, status} <- fetch_required(created, :status),
         {:ok, agent_address} <- fetch_required(created, :agent_address),
         {:ok, network} <- fetch_required(created, :network),
         {:ok, chain_id} <- fetch_required(created, :chain_id),
         {:ok, contract_address} <- fetch_required(created, :contract_address),
         {:ok, nonce} <- fetch_required(created, :nonce),
         {:ok, app_id} <- fetch_required(created, :app_id),
         {:ok, action} <- fetch_required(created, :action),
         {:ok, rp_id} <- fetch_required(created, :rp_id),
         {:ok, signal} <- fetch_required(created, :signal),
         {:ok, rp_context} <- fetch_required(created, :rp_context),
         {:ok, expires_at} <- fetch_required(created, :expires_at) do
      {:ok,
       %{
         session_id: session_id,
         launch_job_id: Map.get(attrs, "launch_job_id"),
         status: status,
         agent_address: agent_address,
         network: network,
         chain_id: chain_id,
         contract_address: contract_address,
         relay_url: Map.get(created, :relay_url),
         nonce: nonce,
         app_id: app_id,
         action: action,
         rp_id: rp_id,
         signal: signal,
         rp_context: rp_context,
         connector_uri: Map.get(created, :connector_uri),
         deep_link_uri: Map.get(created, :deep_link_uri),
         proof_payload: Map.get(created, :proof_payload),
         tx_request: Map.get(created, :tx_request),
         tx_hash: Map.get(created, :tx_hash),
         human_id: Map.get(created, :human_id),
         error_text: Map.get(created, :error_text),
         expires_at: expires_at
       }}
    end
  end

  defp normalize_created_session(_created, _attrs), do: {:error, :invalid_request}

  defp normalize_updated_session(updated) when is_map(updated) do
    %{
      status: Map.get(updated, :status),
      proof_payload: Map.get(updated, :proof_payload),
      tx_request: Map.get(updated, :tx_request),
      tx_hash: Map.get(updated, :tx_hash),
      human_id: Map.get(updated, :human_id),
      error_text: Map.get(updated, :error_text)
    }
  end

  defp normalize_updated_session(_updated), do: %{}

  defp fetch_required(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_request}
    end
  end
end
