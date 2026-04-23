defmodule Autolaunch.Launch.Bids do
  @moduledoc false

  alias Autolaunch.Launch.{BidFlow, Params}

  def quote_bid(auction_id, attrs, current_human \\ nil) do
    BidFlow.quote_bid(auction_id, Params.quote_attrs(attrs), current_human)
  end

  def place_bid(auction_id, attrs, human) do
    BidFlow.place_bid(auction_id, Params.quote_attrs(attrs), human)
  end

  def list_positions(human, filters \\ %{}) do
    BidFlow.list_positions(human, Params.position_filters(filters))
  end

  def exit_bid(bid_id, attrs, human) do
    BidFlow.exit_bid(bid_id, Params.bid_registration_attrs(attrs), human)
  end

  def return_bid(bid_id, attrs, human), do: exit_bid(bid_id, attrs, human)

  def claim_bid(bid_id, attrs, human) do
    BidFlow.claim_bid(bid_id, Params.bid_registration_attrs(attrs), human)
  end
end
