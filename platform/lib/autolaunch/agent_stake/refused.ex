defmodule Autolaunch.AgentStake.Refused do
  @moduledoc """
  An agent's staking action refused: `reason` is always one of the codes the
  agent staking contract documents (`Autolaunch.AgentStake.code/1`), an atom
  such as `:wrong_signer`, `:nothing_to_stake` or `:amount_above_stake`, which
  the HTTP route answers with its status and the hosted MCP tool as its error,
  in the same words (`AutolaunchWeb.AgentStakeAnswer`).
  """
  use Splode.Error, fields: [:reason], class: :unknown

  def message(%{reason: reason}), do: Atom.to_string(reason)
end
