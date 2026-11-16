defmodule Autolaunch.Earn.Refused do
  @moduledoc """
  An Earn operation refused for a reason its surfaces name in words: `reason`
  is the atom (`:unknown_product`, `:invalid_amount`, `:wrong_signer`,
  `:chain_unavailable` and the rest), which the HTTP routes answer with their
  status and the hosted MCP tools as their error, in the same words
  (`AutolaunchWeb.EarnAnswer`).
  """
  use Splode.Error, fields: [:reason], class: :unknown

  def message(%{reason: reason}), do: Atom.to_string(reason)
end
