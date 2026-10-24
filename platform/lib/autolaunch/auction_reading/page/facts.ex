defmodule Autolaunch.AuctionReading.Page.Facts do
  @moduledoc "What an auction's stage settles (`Autolaunch.AuctionStage`)."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :minimum_reached, :boolean, public?: true, allow_nil?: false
    attribute :claims_open, :boolean, public?: true, allow_nil?: false
    attribute :refunds_open, :boolean, public?: true, allow_nil?: false
    attribute :liquidity_locked, :boolean, public?: true
  end
end
