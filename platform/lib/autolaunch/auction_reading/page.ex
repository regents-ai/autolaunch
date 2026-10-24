defmodule Autolaunch.AuctionReading.Page.Block do
  @moduledoc "The block a page was read at."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :number, :integer, public?: true, allow_nil?: false
    attribute :hash, :string, public?: true, allow_nil?: false
    attribute :timestamp, :integer, public?: true, allow_nil?: false
  end
end

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

defmodule Autolaunch.AuctionReading.Page.Step do
  @moduledoc "One step of the release schedule: `mps` per block from `from` to `to`."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :from, :integer, public?: true, allow_nil?: false
    attribute :to, :integer, public?: true, allow_nil?: false
    attribute :mps, :integer, public?: true, allow_nil?: false
  end
end

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

defmodule Autolaunch.AuctionReading.Page.Stage do
  @moduledoc "An auction's stage and what it settles (`Autolaunch.AuctionStage`)."
  use Ash.Resource, data_layer: :embedded

  alias Autolaunch.AuctionReading.Page.Facts

  attributes do
    attribute :stage, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:created, :open, :finishing, :pool_ready, :failed]]

    attribute :facts, Facts, public?: true, allow_nil?: false
  end
end

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
