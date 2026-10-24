defmodule Autolaunch.AuctionReading.Page.Ladder do
  @moduledoc "The price ladder (`Autolaunch.AuctionSnapshot`)."
  use Ash.Resource, data_layer: :embedded

  alias Autolaunch.AuctionReading.Page.{LadderState, Rung}

  attributes do
    attribute :state, LadderState, public?: true, allow_nil?: false
    attribute :complete?, :boolean, public?: true, allow_nil?: false
    attribute :rungs, {:array, Rung}, public?: true, allow_nil?: false
    attribute :more, :integer, public?: true, allow_nil?: false
    attribute :highest_q96, :integer, public?: true
    attribute :prices, :binary, public?: true, allow_nil?: false
  end
end
