defmodule Autolaunch.AgentBid.Refused do
  @moduledoc """
  An agent bid refused for a reason its surfaces name in words: `reason` is the
  atom the review named (`:wrong_signer`, `:invalid_amount`,
  `:amount_above_balance`, `:not_your_bid`, `:claim_not_open` and the rest),
  which the HTTP routes answer with their status and the hosted MCP tools as
  their error, in the same words (`AutolaunchWeb.AgentBidAnswer`).
  """
  use Splode.Error, fields: [:reason], class: :unknown

  def message(%{reason: reason}), do: Atom.to_string(reason)
end
