defmodule Autolaunch.AuctionReading.Page do
  @moduledoc """
  Everything a Base auction's own page shows from the chain, at one block
  (`Autolaunch.AuctionSnapshot.page/6`): the book (`Autolaunch.AuctionBook`),
  the auction's key blocks and amounts, its release schedule, its price ladder
  and its stage. Prices and amounts in Q96 are whole numbers, held exactly;
  the ladder's every price read is one packed binary.
  """

  use Ash.Resource, data_layer: :embedded

  alias __MODULE__.{Block, Blocks, Ladder, Stage, Step}

  attributes do
    attribute :block, Block, public?: true, allow_nil?: false
    attribute :clearing_q96, :integer, public?: true, allow_nil?: false
    attribute :clearing, :string, public?: true, allow_nil?: false
    attribute :decimals, :integer, public?: true, allow_nil?: false
    attribute :tick_spacing_q96, :integer, public?: true, allow_nil?: false
    attribute :max_bid_price_q96, :integer, public?: true, allow_nil?: false
    attribute :price_to_beat_q96, :integer, public?: true
    attribute :price_to_beat, :string, public?: true
    attribute :address, :string, public?: true, allow_nil?: false
    attribute :clock, :integer, public?: true, allow_nil?: false
    attribute :blocks, Blocks, public?: true, allow_nil?: false
    attribute :schedule, {:array, Step}, public?: true, allow_nil?: false
    attribute :ladder, Ladder, public?: true, allow_nil?: false
    attribute :stage, Stage, public?: true, allow_nil?: false
    attribute :raised, :string, public?: true, allow_nil?: false
  end
end
