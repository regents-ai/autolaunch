defmodule AutolaunchWeb.Api.AgentbookController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Agentbook
  alias AutolaunchWeb.ApiErrorTranslator

  import AutolaunchWeb.Api.ControllerHelpers

  def create(conn, params) do
    render_result(conn, Agentbook.create_session(params), :session)
  end

  def show(conn, %{"id" => session_id}) do
    case Agentbook.get_session(session_id) do
      nil -> render_result(conn, {:error, :session_not_found}, :session)
      session -> render_result(conn, {:ok, session}, :session)
    end
  end

  def submit(conn, %{"id" => session_id} = params) do
    render_result(conn, Agentbook.submit_session(session_id, Map.delete(params, "id")), :session)
  end

  def lookup(conn, params) do
    render_result(conn, Agentbook.lookup_human(params), :result)
  end

  def verify(conn, params) do
    render_result(conn, Agentbook.verify_header(params), :result)
  end

  defp render_result(conn, result, root_key),
    do:
      render_api_result(conn, result, &ApiErrorTranslator.translate(:agentbook, &1),
        root_key: root_key
      )
end
