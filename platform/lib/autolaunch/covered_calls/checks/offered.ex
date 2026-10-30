defmodule Autolaunch.CoveredCalls.Checks.Offered do
  @moduledoc """
  Holds while the site offers covered calls (`AUTOLAUNCH_COVERED_CALLS`,
  `Autolaunch.CoveredCalls.Deployment`). Off, the operations every agent surface
  runs are refused, so the hosted MCP server neither lists nor runs them, as the
  routes and browser tools are not there either.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the site offers covered calls"

  @impl true
  def match?(_actor, _context, _opts), do: Autolaunch.CoveredCalls.Deployment.enabled?()
end
