defmodule Autolaunch.Auction.Preparations.BaseOnly do
  @moduledoc false
  use Ash.Resource.Preparation

  # A listed Base auction: one created through this site, which always names
  # its creator, or a Memestock launch sent anywhere, which names only its
  # wallet (`Autolaunch.Stocks.ChainLaunch`). The public lists, which also
  # carry Robinhood rows, use `Autolaunch.Auction.Preparations.Listed`.
  @impl true
  def prepare(query, _opts, _context) do
    query
    |> created(Autolaunch.Stocks.Lab.chain_id())
    |> exclude_robinhood(Autolaunch.Robinhood.Lab.chain_id())
  end

  defp created(query, nil), do: Ash.Query.filter(query, not is_nil(creator_human_account_id))

  defp created(query, base),
    do:
      Ash.Query.filter(
        query,
        not is_nil(creator_human_account_id) or
          (origin == :chain and kind == :stocks and chain_id == ^base)
      )

  defp exclude_robinhood(query, nil), do: query

  defp exclude_robinhood(query, chain_id),
    do: Ash.Query.filter(query, chain_id != ^chain_id)
end
