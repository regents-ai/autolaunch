defmodule Autolaunch.Listings do
  @moduledoc """
  Saved changes to what the public lists show. `Autolaunch.Auction` and
  `Autolaunch.Token` publish `{:autolaunch_listings_changed, auction_id}` on
  this topic for a new auction or token, an auction whose state or minimum
  changed, and an auction's bid terms or treasury report. Price readings
  travel on the market feed's own topic instead.
  """

  @topic "listings"

  @doc "The topic the resources publish on; their `pub_sub` blocks name it too."
  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, @topic)
end
