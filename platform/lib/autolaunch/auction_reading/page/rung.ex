defmodule Autolaunch.AuctionReading.Page.Rung do
  @moduledoc "One listed price, the demand bidding there and the demand it needs."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :price_q96, :integer, public?: true, allow_nil?: false
    attribute :price, :string, public?: true, allow_nil?: false
    attribute :bidding, :string, public?: true, allow_nil?: false
    attribute :needed, :string, public?: true, allow_nil?: false
  end
end
