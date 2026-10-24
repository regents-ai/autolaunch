defmodule Autolaunch.AuctionReading.Market do
  @moduledoc """
  An auction's figures from its last reading (`Autolaunch.AuctionReading`):
  its key blocks, what it has raised and has left to sell, both written out in
  whole units, and its pool's price once it graduated. Robinhood blocks are the
  rollup clock the contracts keep time by; Robinhood reads no claim block and
  no supply left, so both are nil there.
  """

  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :start_block, :integer, public?: true, allow_nil?: false
    attribute :end_block, :integer, public?: true, allow_nil?: false
    attribute :claim_block, :integer, public?: true
    attribute :currency_raised, :string, public?: true, allow_nil?: false
    attribute :remaining_supply, :string, public?: true
    attribute :price_quote, :string, public?: true
  end
end
