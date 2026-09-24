defmodule Autolaunch.Auction.Preparations.Listed do
  @moduledoc false
  use Ash.Resource.Preparation

  # The public lists across both chains: a Base auction is listed when it was
  # created through this site, which always names its creator; every
  # Robinhood launchpad record is listed, creator or not.
  @impl true
  def prepare(query, _opts, _context),
    do: listed(query, Autolaunch.Robinhood.Lab.chain_id())

  defp listed(query, nil), do: Ash.Query.filter(query, not is_nil(creator_human_account_id))

  defp listed(query, robinhood),
    do: Ash.Query.filter(query, not is_nil(creator_human_account_id) or chain_id == ^robinhood)
end
