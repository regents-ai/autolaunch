defmodule Autolaunch.Auction.Preparations.Shown do
  @moduledoc false
  use Ash.Resource.Preparation

  # The public lists and pages leave out an auction an operator hid; see
  # `Autolaunch.Auction`'s `:hide`. Its bidders' own records still read it.
  @impl true
  def prepare(query, _opts, _context), do: Ash.Query.filter(query, not hidden)
end
