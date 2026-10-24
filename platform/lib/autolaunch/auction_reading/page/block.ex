defmodule Autolaunch.AuctionReading.Page.Block do
  @moduledoc "The block a page was read at."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :number, :integer, public?: true, allow_nil?: false
    attribute :hash, :string, public?: true, allow_nil?: false
    attribute :timestamp, :integer, public?: true, allow_nil?: false
  end
end
