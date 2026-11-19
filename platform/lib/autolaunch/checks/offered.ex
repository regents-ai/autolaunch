defmodule Autolaunch.Checks.Offered do
  @moduledoc """
  Holds while the site offers the agent feature `feature` names, by that
  feature's own switch (`enabled?/0`): agent bids (`Autolaunch.AgentBid`),
  agent Robinhood bids (`Autolaunch.AgentRobinhoodBid`), agent launches
  (`Autolaunch.AgentLaunch`), agent finishes (`Autolaunch.AgentFinish`),
  agent staking (`Autolaunch.AgentStake`) or agent swaps
  (`Autolaunch.AgentSwap`), each resource naming itself. Off,
  the hosted MCP server neither lists nor runs the feature's tools, as its
  routes (`AutolaunchWeb.Router.admit_offered/2`) and browser tools are not
  there either.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "the site offers #{inspect(Keyword.fetch!(opts, :feature))}"

  @impl true
  def match?(_actor, _context, opts), do: Keyword.fetch!(opts, :feature).enabled?()
end
