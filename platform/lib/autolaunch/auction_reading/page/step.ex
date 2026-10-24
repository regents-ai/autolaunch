defmodule Autolaunch.AuctionReading.Page.Step do
  @moduledoc "One step of the release schedule: `mps` per block from `from` to `to`."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :from, :integer, public?: true, allow_nil?: false
    attribute :to, :integer, public?: true, allow_nil?: false
    attribute :mps, :integer, public?: true, allow_nil?: false
  end
end
