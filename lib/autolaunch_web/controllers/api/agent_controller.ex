defmodule AutolaunchWeb.Api.AgentController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias AutolaunchWeb.ApiError

  def index(conn, params) do
    current_human = conn.assigns[:current_human]

    agents =
      launch_module().list_agents(current_human)
      |> maybe_filter_launchable(Map.get(params, "launchable"))

    json(conn, %{ok: true, items: agents})
  end

  def show(conn, %{"id" => id}) do
    current_human = conn.assigns[:current_human]

    case launch_module().get_agent(current_human, id) do
      nil -> ApiError.render(conn, :not_found, "agent_not_found", "Agent not found")
      agent -> json(conn, %{ok: true, agent: agent})
    end
  end

  def readiness(conn, %{"id" => id}) do
    current_human = conn.assigns[:current_human]

    case launch_module().launch_readiness_for_agent(current_human, id) do
      nil ->
        ApiError.render(conn, :not_found, "readiness_not_found", "Agent readiness not found")

      readiness ->
        agent = launch_module().get_agent(current_human, id) || %{}

        json(conn, %{
          ok: true,
          agent_id: id,
          agent_name: Map.get(agent, :name),
          launch_eligible: readiness.ready_to_launch,
          launch_blockers: launch_blockers(readiness),
          existing_token: Map.get(agent, :existing_token),
          supported_chains: Map.get(agent, :supported_chains, []),
          readiness: readiness
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
    :autolaunch
    |> Application.get_env(:agent_controller, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
