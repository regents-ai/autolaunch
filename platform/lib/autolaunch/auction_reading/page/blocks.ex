defmodule Autolaunch.AuctionReading.Page.Blocks do
  @moduledoc "An auction's key blocks and its totals, in the contract's own units."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :start, :integer, public?: true, allow_nil?: false
    attribute :end, :integer, public?: true, allow_nil?: false
    attribute :claim, :integer, public?: true, allow_nil?: false
    attribute :supply, :integer, public?: true, allow_nil?: false
    attribute :cleared, :integer, public?: true, allow_nil?: false
    attribute :raised, :integer, public?: true, allow_nil?: false
  end
end
