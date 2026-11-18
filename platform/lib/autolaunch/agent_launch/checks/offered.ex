defmodule Autolaunch.AgentLaunch.Checks.Offered do
  @moduledoc """
  Holds while the site offers agent launches (`AUTOLAUNCH_AGENT_LAUNCHES`,
  `Autolaunch.AgentLaunch.enabled?/0`). Off, the hosted MCP server neither
  lists nor runs its tool, as the route and browser tool are not there either.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the site offers agent launches"

  @impl true
  def match?(_actor, _context, _opts), do: Autolaunch.AgentLaunch.enabled?()
end
