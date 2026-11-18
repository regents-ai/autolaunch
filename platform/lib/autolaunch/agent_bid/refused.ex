defmodule Autolaunch.AgentBid.Refused do
  @moduledoc """
  An agent bid refused: `reason` is always one of the codes the agent bid
  contract documents (`Autolaunch.AgentBid.code/1`), an atom such as
  `:wrong_signer`, `:bidding_ended` or `:not_your_bid`, which the HTTP routes
  answer with its status and the hosted MCP tools as their error, in the same
  words (`AutolaunchWeb.AgentBidAnswer`).
  """
  use Splode.Error, fields: [:reason], class: :unknown

  def message(%{reason: reason}), do: Atom.to_string(reason)
end
