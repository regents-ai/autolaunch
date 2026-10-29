defmodule Autolaunch.Auction.Preparations.Listed do
  @moduledoc false
  use Ash.Resource.Preparation

  # The public lists across both chains carry the auctions launched through
  # this site and every Memestock launch on Base, wherever it was sent
  # (`Autolaunch.Stocks.ChainLaunch`); any other launch seen only on chain is
  # stored but not listed.
  @impl true
  def prepare(query, _opts, _context), do: listed(query, Autolaunch.Stocks.Lab.chain_id())

  defp listed(query, nil), do: Ash.Query.filter(query, origin == :site)

  defp listed(query, base),
    do:
      Ash.Query.filter(
        query,
        origin == :site or (origin == :chain and kind == :stocks and chain_id == ^base)
      )
end
