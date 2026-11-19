defmodule Autolaunch.AgentSwap.Refused do
  @moduledoc """
  An agent's swap refused: `reason` is always one of the codes the agent swaps
  contract documents (`Autolaunch.AgentSwap.code/1`), an atom such as
  `:wrong_signer`, `:quote_unavailable` or `:amount_above_balance`, which the
  HTTP route answers with its status and the hosted MCP tool as its error, in
  the same words (`AutolaunchWeb.AgentSwapAnswer`).
  """
  use Splode.Error, fields: [:reason], class: :unknown

  def message(%{reason: reason}), do: Atom.to_string(reason)
end
