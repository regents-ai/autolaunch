defmodule Autolaunch.Token.Preparations.ListedAuction do
  @moduledoc false
  use Ash.Resource.Preparation

  # A token is listed when its auction is: see
  # `Autolaunch.Auction.Preparations.Listed`.
  @impl true
  def prepare(query, _opts, _context),
    do: listed(query, Autolaunch.Robinhood.Lab.chain_id())

  defp listed(query, nil),
    do: Ash.Query.filter(query, exists(auction, not is_nil(creator_human_account_id)))

  defp listed(query, robinhood),
    do:
      Ash.Query.filter(
        query,
        exists(auction, not is_nil(creator_human_account_id) or chain_id == ^robinhood)
      )
end
