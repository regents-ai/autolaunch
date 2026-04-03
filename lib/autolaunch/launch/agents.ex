defmodule Autolaunch.Launch.Agents do
  @moduledoc false

  alias Autolaunch.Launch.Internal

  def fee_split_summary, do: Internal.fee_split_summary()
  def chain_options, do: Internal.chain_options()

  def record_world_agentbook_completion(launch_job_id, attrs),
    do: Internal.record_world_agentbook_completion(launch_job_id, attrs)

  def list_agents(human), do: Internal.list_agents(human)
  def get_agent(human, agent_id), do: Internal.get_agent(human, agent_id)
  def controls_agent?(human, agent_id), do: Internal.controls_agent?(human, agent_id)

  def launch_readiness_for_agent(human, agent_id),
    do: Internal.launch_readiness_for_agent(human, agent_id)
end
