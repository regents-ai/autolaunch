defmodule AutolaunchWeb.Api.AgentController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias Autolaunch.Prelaunch
  alias AutolaunchWeb.ApiError

  import AutolaunchWeb.Api.ControllerHelpers

  def index(conn, params) do
    actor = current_actor(conn)

    agents =
      launch_module().list_agents(actor)
      |> maybe_filter_launchable(Map.get(params, "launchable"))

    json(conn, %{ok: true, items: agents})
  end

  def show(conn, %{"id" => id}) do
    actor = current_actor(conn)

    case launch_module().get_agent(actor, id) do
      nil -> ApiError.render(conn, :not_found, "agent_not_found", "Agent not found")
      agent -> json(conn, %{ok: true, agent: agent})
    end
  end

  def readiness(conn, %{"id" => id}) do
    actor = current_actor(conn)

    case launch_module().launch_readiness_for_agent(actor, id) do
      nil ->
        ApiError.render(conn, :not_found, "readiness_not_found", "Agent readiness not found")

      readiness ->
        agent = launch_module().get_agent(actor, id) || %{}

        json(conn, %{
          ok: true,
          agent_id: id,
          agent_name: Map.get(agent, :name),
          launch_eligible: readiness.ready_to_launch,
          launch_blockers: launch_blockers(readiness),
          existing_token: Map.get(agent, :existing_token),
          supported_chains: Map.get(agent, :supported_chains, []),
          readiness: readiness,
          supporting_evidence: supporting_evidence(actor, id)
        })
    end
  end

  defp maybe_filter_launchable(agents, value) when value in ["true", "1"],
    do: Enum.filter(agents, &(&1.state == "eligible"))

  defp maybe_filter_launchable(agents, _value), do: agents

  defp launch_blockers(readiness) do
    readiness.checks
    |> Enum.reject(& &1.passed)
    |> Enum.map(& &1.message)
  end

  defp launch_module do
    configured_module(:agent_controller, :launch_module, Launch)
  end

  defp prelaunch_module do
    configured_module(:agent_controller, :prelaunch_module, Prelaunch)
  end

  defp supporting_evidence(actor, agent_id) do
    {:ok, evidence} = prelaunch_module().supporting_evidence_for_agent(agent_id, actor)
    evidence
  end

  defp current_actor(conn),
    do: conn.assigns[:current_agent_claims] || conn.assigns[:current_human]
end
