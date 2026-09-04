defmodule Autolaunch.Auction.Preparations.SiteCreatedOnly do
  @moduledoc false
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.filter(query, not is_nil(creator_human_account_id))
  end
end
