defmodule Autolaunch.AuctionReading.Page.LadderState do
  @moduledoc "The auction's stored state a ladder was read from."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :checkpoint_block, :integer, public?: true, allow_nil?: false
    attribute :clearing_q96, :integer, public?: true, allow_nil?: false
    attribute :remaining_mps, :integer, public?: true, allow_nil?: false
    attribute :remaining_supply_q96x7, :integer, public?: true, allow_nil?: false
    attribute :demand_above_q96, :integer, public?: true, allow_nil?: false
  end
end
