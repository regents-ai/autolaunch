defmodule Autolaunch.Auction.Preparations.Listed do
  @moduledoc false
  use Ash.Resource.Preparation

  # The public lists across both chains carry the auctions launched through
  # this site and every Memestock launch on Base, wherever it was sent
  # (`Autolaunch.Stocks.ChainLaunch`); a Robinhood launch seen only on chain is
  # stored but not listed.
  @impl true
  def prepare(query, _opts, _context), do: listed(query, Autolaunch.Robinhood.Lab.chain_id())

  defp listed(query, nil), do: query

  defp listed(query, robinhood),
    do: Ash.Query.filter(query, origin == :site or chain_id != ^robinhood)
end
