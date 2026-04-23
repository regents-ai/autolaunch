defmodule Autolaunch.Launch.Agents do
  @moduledoc false

  alias Autolaunch.Launch.Core

  def fee_split_summary, do: Core.fee_split_summary()
  def chain_options, do: Core.chain_options()

  def record_world_agentbook_completion(launch_job_id, attrs),
    do: Core.record_world_agentbook_completion(launch_job_id, attrs)

  def list_agents(human), do: Core.list_agents(human)
  def get_agent(human, agent_id), do: Core.get_agent(human, agent_id)
  def controls_agent?(human, agent_id), do: Core.controls_agent?(human, agent_id)

  def launch_readiness_for_agent(human, agent_id),
    do: Core.launch_readiness_for_agent(human, agent_id)
end
