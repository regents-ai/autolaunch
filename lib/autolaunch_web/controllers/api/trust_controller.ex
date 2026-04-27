defmodule AutolaunchWeb.Api.TrustController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Trust
  alias AutolaunchWeb.ApiError

  import AutolaunchWeb.Api.ControllerHelpers

  def show_agent(conn, %{"id" => agent_id}) do
    case context_module().summary_for_agent(agent_id) do
      %{} = trust ->
        json(conn, %{ok: true, agent_id: agent_id, trust: trust})

      {:error, :invalid_agent_id} ->
        ApiError.render(conn, :unprocessable_entity, "invalid_agent_id", "Agent id is invalid")

      _ ->
        ApiError.render(conn, :not_found, "agent_not_found", "Agent trust record not found")
    end
  end

  def start_x(conn, %{"agent_id" => agent_id}) do
    with_current_human(conn, fn human ->
      case context_module().prepare_x_link(human, agent_id) do
        {:ok, %{identity: identity, provider: provider, trust_provider: trust_provider}} ->
          json(conn, %{
            ok: true,
            provider: provider,
            trust_provider: trust_provider,
            agent_id: identity.agent_id,
            redirect_path: ~p"/x-link?identity_id=#{identity.agent_id}"
          })

        {:error, reason} ->
          render_x_start_error(conn, reason)
      end
    end)
  end

  def complete_x(conn, params) do
    with_current_human(conn, fn human ->
      case context_module().upsert_x_account(human, params) do
        {:ok, account} ->
          trust = context_module().summary_for_agent(account.agent_id)
          json(conn, %{ok: true, agent_id: account.agent_id, trust: trust})

        {:error, reason} ->
          render_x_complete_error(conn, reason)
      end
    end)
  end

  defp render_x_start_error(conn, :agent_not_found) do
    ApiError.render(conn, :not_found, "agent_not_found", "Agent not found for this session")
  end

  defp render_x_start_error(conn, :unauthorized) do
    ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")
  end

  defp render_x_start_error(conn, _reason) do
    ApiError.render(conn, :unprocessable_entity, "x_link_invalid", "Unable to start X link")
  end

  defp render_x_complete_error(conn, :agent_not_found) do
    ApiError.render(conn, :not_found, "agent_not_found", "Agent not found for this session")
  end

  defp render_x_complete_error(conn, :invalid_x_account) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "invalid_x_account",
      "X account details were incomplete"
    )
  end

  defp render_x_complete_error(conn, _reason) do
    ApiError.render(
      conn,
      :unprocessable_entity,
      "x_link_persist_failed",
      "The X connection could not be saved"
    )
  end

  defp context_module do
    configured_module(:trust_controller, :trust_module, Trust)
  end
end
