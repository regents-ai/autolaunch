defmodule Autolaunch.Auction.Preparations.Listed do
  @moduledoc false
  use Ash.Resource.Preparation

  # The public lists across both chains carry the auctions launched through
  # this site; a launch seen only on chain is stored but not listed.
  @impl true
  def prepare(query, _opts, _context), do: Ash.Query.filter(query, origin == :site)
end
