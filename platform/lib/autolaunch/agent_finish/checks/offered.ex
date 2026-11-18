defmodule Autolaunch.AgentFinish.Checks.Offered do
  @moduledoc """
  Holds while the site offers agent finishes (`AUTOLAUNCH_AGENT_FINISH`,
  `Autolaunch.AgentFinish.enabled?/0`). Off, the hosted MCP server neither
  lists nor runs their tool, as the route and browser tool are not there
  either.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the site offers agent finishes"

  @impl true
  def match?(_actor, _context, _opts), do: Autolaunch.AgentFinish.enabled?()
end
