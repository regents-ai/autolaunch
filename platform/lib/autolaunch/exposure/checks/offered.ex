defmodule Autolaunch.Exposure.Checks.Offered do
  @moduledoc """
  Holds while the site offers Isolated Exposure to After-hours Stocks
  (`AUTOLAUNCH_EXPOSURE`, `Autolaunch.Exposure.Deployment`). Off, the reads the
  hosted MCP tools run are refused, so the hosted MCP server neither lists nor
  runs them, as the routes and browser tools are not there either.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the site offers Isolated Exposure to After-hours Stocks"

  @impl true
  def match?(_actor, _context, _opts), do: Autolaunch.Exposure.Deployment.enabled?()
end
