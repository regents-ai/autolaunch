defmodule Autolaunch.Token.Preparations.ListedAuction do
  @moduledoc false
  use Ash.Resource.Preparation

  # A token is listed when its auction is: see
  # `Autolaunch.Auction.Preparations.Listed`.
  @impl true
  def prepare(query, _opts, _context),
    do: Ash.Query.filter(query, exists(auction, origin == :site))
end
