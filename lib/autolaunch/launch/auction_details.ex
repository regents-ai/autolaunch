defmodule Autolaunch.Launch.AuctionDetails do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.Core
  alias Autolaunch.Repo

  def get_auction(auction_id, current_human \\ nil) do
    with {:ok, active_chain_id} <- Core.launch_chain_id() do
      Repo.one(
        from auction in Auction,
          where:
            fragment("coalesce(?, '')", auction.source_job_id) == ^auction_id and
              auction.chain_id == ^active_chain_id,
          limit: 1
      )
      |> case do
        nil ->
          nil

        auction ->
          serialize_single_auction(auction, current_human)
      end
    else
      _ -> nil
    end
  rescue
    DBConnection.ConnectionError -> nil
    Postgrex.Error -> nil
    Ecto.QueryError -> nil
  end

  def get_auction_by_address(network, auction_address, current_human) do
    Repo.get_by(Auction, network: network, auction_address: auction_address)
    |> case do
      nil -> nil
      auction -> serialize_single_auction(auction, current_human)
    end
  rescue
    _ -> nil
  end

  defp serialize_single_auction(%Auction{} = auction, current_human) do
    Core.serialize_auction(
      auction,
      current_human,
      Core.identity_index_for_auctions([auction]),
      Core.job_index_for_auctions([auction]),
      Core.world_launch_counts(),
      Core.x_accounts_for_auctions([auction])
    )
  end
end
