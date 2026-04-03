defmodule Autolaunch.Launch.Auctions do
  @moduledoc false

  alias Autolaunch.Launch.{Internal, Params}

  def list_auctions(filters \\ %{}, current_human \\ nil) do
    Internal.list_auctions(Params.auction_filters(filters), current_human)
  end

  def list_auction_returns(filters \\ %{}, current_human \\ nil) do
    Internal.list_auction_returns(Params.return_filters(filters), current_human)
  end

  def get_auction(auction_id, current_human \\ nil),
    do: Internal.get_auction(auction_id, current_human)
end
