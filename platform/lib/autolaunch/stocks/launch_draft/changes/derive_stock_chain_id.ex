defmodule Autolaunch.Stocks.LaunchDraft.Changes.DeriveStockChainId do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.{LaunchChain, Stocks.Assets}

  # A draft's stock currency lives on the chain the draft launches on: Base
  # stocks for a Base draft, the local lab's fixture stocks for a Robinhood one.
  # The chain is the accepted or default attribute, never a caller-supplied id.
  @impl true
  def change(changeset, _opts, _context) do
    chain = Ash.Changeset.get_attribute(changeset, :chain)

    if chain in LaunchChain.chains(),
      do:
        Ash.Changeset.force_change_attribute(changeset, :stock_chain_id, Assets.chain_id(chain)),
      else: Ash.Changeset.add_error(changeset, field: :chain, message: "is not a launch chain")
  end
end
