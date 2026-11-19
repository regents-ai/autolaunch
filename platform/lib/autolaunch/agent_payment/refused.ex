defmodule Autolaunch.AgentPayment.Refused do
  @moduledoc """
  An agent's payment refused: `reason` is always one of the codes the agent
  payments contract documents (`Autolaunch.AgentPayment.code/1`), an atom such
  as `:wrong_signer`, `:split_mismatch` or `:nothing_to_sweep`, which the HTTP
  route answers with its status and the hosted MCP tool as its error, in the
  same words (`AutolaunchWeb.AgentPaymentAnswer`).
  """
  use Splode.Error, fields: [:reason], class: :unknown

  def message(%{reason: reason}), do: Atom.to_string(reason)
end
