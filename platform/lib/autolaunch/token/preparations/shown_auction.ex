defmodule Autolaunch.Token.Preparations.ShownAuction do
  @moduledoc false
  use Ash.Resource.Preparation

  # A token is shown when its auction is: see
  # `Autolaunch.Auction.Preparations.Shown`.
  @impl true
  def prepare(query, _opts, _context), do: Ash.Query.filter(query, exists(auction, not hidden))
end
