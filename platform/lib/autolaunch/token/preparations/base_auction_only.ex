defmodule Autolaunch.Token.Preparations.BaseAuctionOnly do
  @moduledoc false
  use Ash.Resource.Preparation

  # A token whose auction is a listed Base auction: one created through this
  # site, or a Memestock launch sent anywhere (`Autolaunch.Stocks.ChainLaunch`).
  # The public lists, which also carry Robinhood tokens, use
  # `Autolaunch.Token.Preparations.ListedAuction`.
  @impl true
  def prepare(query, _opts, _context),
    do: base(query, Autolaunch.Robinhood.Lab.chain_id(), Autolaunch.Stocks.Lab.chain_id())

  defp base(query, nil, nil), do: Ash.Query.filter(query, exists(auction, origin == :site))

  defp base(query, robinhood, nil),
    do: Ash.Query.filter(query, exists(auction, origin == :site and chain_id != ^robinhood))

  defp base(query, nil, base),
    do:
      Ash.Query.filter(
        query,
        exists(
          auction,
          origin == :site or (origin == :chain and kind == :stocks and chain_id == ^base)
        )
      )

  defp base(query, robinhood, base),
    do:
      Ash.Query.filter(
        query,
        exists(
          auction,
          (origin == :site and chain_id != ^robinhood) or
            (origin == :chain and kind == :stocks and chain_id == ^base)
        )
      )
end
