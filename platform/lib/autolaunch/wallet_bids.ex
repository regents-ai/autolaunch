defmodule Autolaunch.WalletBids do
  @moduledoc """
  Saved changes to one wallet's bids. `Autolaunch.Bid` publishes
  `{:autolaunch_bid_changed, bid_id}` on the owner's topic each time a bid's
  standing is written: when its auction ends, when it is withdrawn and when its
  tokens become claimable or are claimed.
  """

  @doc "Subscribes the calling process to the bids of one lowercase wallet address."
  def subscribe("0x" <> _ = wallet),
    do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, "wallet_bids:" <> wallet)
end
