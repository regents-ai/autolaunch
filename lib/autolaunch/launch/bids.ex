defmodule Autolaunch.Launch.Bids do
  @moduledoc false

  alias Autolaunch.Launch.{Internal, Params}

  def quote_bid(auction_id, attrs, current_human \\ nil) do
    Internal.quote_bid(auction_id, Params.quote_attrs(attrs), current_human)
  end

  def place_bid(auction_id, attrs, human) do
    Internal.place_bid(auction_id, Params.quote_attrs(attrs), human)
  end

  def list_positions(human, filters \\ %{}) do
    Internal.list_positions(human, Params.position_filters(filters))
  end

  def exit_bid(bid_id, attrs, human) do
    Internal.exit_bid(bid_id, Params.bid_registration_attrs(attrs), human)
  end

  def return_bid(bid_id, attrs, human), do: exit_bid(bid_id, attrs, human)

  def claim_bid(bid_id, attrs, human) do
    Internal.claim_bid(bid_id, Params.bid_registration_attrs(attrs), human)
  end
end
