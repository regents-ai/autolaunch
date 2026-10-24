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
