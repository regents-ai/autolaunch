defmodule AutolaunchWeb.Api.AgentPairingController do
  use AutolaunchWeb, :controller

  alias Autolaunch.AgentPairings
  alias AutolaunchWeb.ApiErrorTranslator
  alias AutolaunchWeb.ClientIp

  import AutolaunchWeb.Api.ControllerHelpers

  def create(conn, _params) do
    with_current_human(conn, fn current_human ->
      render_api_result(
        conn,
        agent_pairings_module().create_session(current_human),
        &ApiErrorTranslator.translate(:agent_pairings, &1),
        root_key: :session,
        status: :created
      )
    end)
  end

  def show(conn, %{"id" => session_id}) do
    with_current_human(conn, fn current_human ->
      render_api_result(
        conn,
        agent_pairings_module().get_session(current_human, session_id),
        &ApiErrorTranslator.translate(:agent_pairings, &1),
        root_key: :session
      )
    end)
  end

  def complete(conn, params) do
    render_api_result(
      conn,
      agent_pairings_module().complete_session(params, completion_ip: ClientIp.from_conn(conn)),
      &ApiErrorTranslator.translate(:agent_pairings, &1),
      root_key: :session
    )
  end

  defp agent_pairings_module do
    configured_module(:agent_pairing_controller, :agent_pairings_module, AgentPairings)
  end
end
