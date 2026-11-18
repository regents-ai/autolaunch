defmodule Autolaunch.AgentLaunch.Refused do
  @moduledoc """
  An agent launch refused: `reason` is always one of the codes the agent launch
  contract documents (`Autolaunch.AgentLaunch.code/1`), an atom such as
  `:wrong_signer`, `:launches_paused` or `:launch_draft_not_found`, which the
  HTTP route answers with its status and the hosted MCP tool as its error, in
  the same words (`AutolaunchWeb.AgentLaunchAnswer`).
  """
  use Splode.Error, fields: [:reason], class: :unknown

  def message(%{reason: reason}), do: Atom.to_string(reason)
end
