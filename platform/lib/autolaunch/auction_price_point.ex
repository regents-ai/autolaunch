defmodule Autolaunch.AuctionPricePoint do
  @moduledoc """
  Confirmed clearing prices an auction contract announced. The contract names
  a price whenever it records a block's checkpoint and whenever a bid raises
  the price within a block; `clock_block` is that block on the auction's own
  clock. `sold` is what the auction had raised by the end of that event's
  block. Derived from chain events like `Autolaunch.BidActivity`.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "auction_price_points"
    repo Autolaunch.Repo
  end

  actions do
    read :for_auction do
      argument :auction_id, :uuid, allow_nil?: false
      filter expr(auction_id == ^arg(:auction_id))
      prepare build(sort: [block_number: :asc, log_index: :asc])
    end

    # The auction's last price event in a block before `block_number`.
    read :latest_before do
      get? true
      argument :auction_id, :uuid, allow_nil?: false
      argument :block_number, :integer, allow_nil?: false

      filter expr(auction_id == ^arg(:auction_id) and block_number < ^arg(:block_number))
      prepare build(sort: [block_number: :desc, log_index: :desc], limit: 1)
    end

    create :record do
      accept [:auction_id, :block_number, :log_index, :clock_block, :clearing_price, :sold]
      upsert? true
      upsert_identity :auction_event
      upsert_fields [:clock_block, :clearing_price, :sold]
    end
  end

  policies do
    policy action(:for_auction) do
      authorize_if always()
    end

    policy action([:latest_before, :record]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :block_number, :integer, allow_nil?: false
    attribute :log_index, :integer, allow_nil?: false
    attribute :clock_block, :integer, allow_nil?: false
    # Whole currency per whole token.
    attribute :clearing_price, :decimal, allow_nil?: false, constraints: [min: 0]
    # Whole currency.
    attribute :sold, :decimal, allow_nil?: false, constraints: [min: 0]
  end

  relationships do
    belongs_to :auction, Autolaunch.Auction do
      allow_nil? false
      read_action :listed
    end
  end

  identities do
    identity :auction_event, [:auction_id, :block_number, :log_index]
  end
end
