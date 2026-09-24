defmodule Autolaunch.Token.Preparations.SiteCreatedAuctionOnly do
  @moduledoc false
  use Ash.Resource.Preparation

  # A token whose auction is a Base auction created through this site. The
  # public lists, which also carry Robinhood tokens, use
  # `Autolaunch.Token.Preparations.ListedAuction`.
  @impl true
  def prepare(query, _opts, _context),
    do: site_created(query, Autolaunch.Robinhood.Lab.chain_id())

  defp site_created(query, nil),
    do: Ash.Query.filter(query, exists(auction, not is_nil(creator_human_account_id)))

  defp site_created(query, robinhood),
    do:
      Ash.Query.filter(
        query,
        exists(auction, not is_nil(creator_human_account_id) and chain_id != ^robinhood)
      )
end
