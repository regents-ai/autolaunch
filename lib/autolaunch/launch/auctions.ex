defmodule Autolaunch.Launch.Auctions do
  @moduledoc false

  alias Autolaunch.Launch.{AuctionDetails, Directory, Params}

  def list_auctions(filters \\ %{}, current_human \\ nil) do
    Directory.list_auctions(Params.auction_filters(filters), current_human)
  end

  def list_auction_returns(filters \\ %{}, current_human \\ nil) do
    Directory.list_auction_returns(Params.return_filters(filters), current_human)
  end

  def get_auction(auction_id, current_human \\ nil),
    do: AuctionDetails.get_auction(auction_id, current_human)
end
