defmodule Autolaunch.Token.Preparations.BaseAuctionOnly do
  @moduledoc false
  use Ash.Resource.Preparation

  # A token whose auction is a listed Base auction: one launched through this
  # site, or a Memestock launch sent anywhere (`Autolaunch.Stocks.ChainLaunch`).
  # The public lists, which also carry Robinhood tokens, use
  # `Autolaunch.Token.Preparations.ListedAuction`.
  @impl true
  def prepare(query, _opts, _context), do: base(query, Autolaunch.Robinhood.Lab.chain_id())

  defp base(query, nil), do: Ash.Query.filter(query, exists(auction, true))

  defp base(query, robinhood),
    do: Ash.Query.filter(query, exists(auction, chain_id != ^robinhood))
end
