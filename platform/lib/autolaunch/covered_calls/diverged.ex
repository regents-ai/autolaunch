defmodule Autolaunch.CoveredCalls.Diverged do
  @moduledoc """
  A covered-call sale read again from the chain that does not match the row
  already saved for it (`Autolaunch.CoveredCalls.Sale` `:record`). The reader
  stops its contract at `block` until the record is put right by hand.
  """
  use Splode.Error, fields: [:block], class: :invalid

  def message(%{block: block}),
    do: "the sale at block #{block} differs from the one already saved from the chain"
end
