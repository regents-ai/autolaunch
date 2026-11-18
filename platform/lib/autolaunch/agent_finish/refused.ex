defmodule Autolaunch.AgentFinish.Refused do
  @moduledoc """
  An agent's finish refused: `reason` is one of the codes the agent finish
  contract documents, an atom such as `:wrong_signer`, `:finish_not_open` or
  `:auction_finished`, which the HTTP route answers with its status and the
  hosted MCP tool as its error, in the same words
  (`AutolaunchWeb.AgentFinishAnswer`). Most are the code
  `Autolaunch.AgentFinish.code/1` gives for the reason a step named; a finish
  that is not open yet is `:finish_not_open` and carries the block finishing
  opens at (`opens_at`), which those words name; input the action does not
  take is `:invalid_request`, refused before it runs.
  """
  use Splode.Error, fields: [:reason, :opens_at], class: :unknown

  def message(%{reason: :finish_not_open, opens_at: opens_at}),
    do: "finish_not_open: finishing opens at block #{opens_at}"

  def message(%{reason: reason}), do: Atom.to_string(reason)
end
