defmodule Autolaunch.AgentFinish.Refused do
  @moduledoc """
  An agent's finish refused: `reason` is always one of the codes the agent
  finish contract documents (`Autolaunch.AgentFinish.code/1`), an atom such as
  `:wrong_signer`, `:finish_not_open` or `:auction_finished`, which the HTTP
  route answers with its status and the hosted MCP tool as its error, in the
  same words (`AutolaunchWeb.AgentFinishAnswer`). A finish that is not open yet
  also carries the block finishing opens at (`opens_at`), which those words
  name.
  """
  use Splode.Error, fields: [:reason, :opens_at], class: :unknown

  def message(%{reason: reason}), do: Atom.to_string(reason)
end
