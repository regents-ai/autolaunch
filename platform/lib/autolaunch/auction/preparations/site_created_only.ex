defmodule Autolaunch.Auction.Preparations.SiteCreatedOnly do
  @moduledoc false
  use Ash.Resource.Preparation

  # The Base listing policy: only auctions created through this site, which
  # always name their creator. Robinhood rows follow their own listing policy
  # (every launchpad record) and are read through their own actions.
  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.filter(not is_nil(creator_human_account_id))
    |> exclude_robinhood(Autolaunch.Robinhood.Lab.chain_id())
  end

  defp exclude_robinhood(query, nil), do: query

  defp exclude_robinhood(query, chain_id),
    do: Ash.Query.filter(query, chain_id != ^chain_id)
end
