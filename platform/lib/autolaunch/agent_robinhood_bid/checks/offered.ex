defmodule Autolaunch.AgentRobinhoodBid.Checks.Offered do
  @moduledoc """
  Holds while the site offers agent Robinhood bids
  (`AUTOLAUNCH_AGENT_ROBINHOOD_BIDS`, `Autolaunch.AgentRobinhoodBid.enabled?/0`).
  Off, the hosted MCP server neither lists nor runs their tools, as the routes
  and browser tools are not there either.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the site offers agent Robinhood bids"

  @impl true
  def match?(_actor, _context, _opts), do: Autolaunch.AgentRobinhoodBid.enabled?()
end
