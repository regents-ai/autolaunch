defmodule Autolaunch.BidActivity do
  @moduledoc """
  Confirmed public bid events, with the wallet that owns each bid. No pending
  transactions. `clock_block` is the block on the auction's own clock the bid
  landed in, which is what its start and end blocks count.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "bid_activity"
    repo Autolaunch.Repo

    custom_indexes do
      index [:auction_id, :block_number]
      index ["occurred_at DESC", "id"], name: "bid_activity_recent_index"
    end
  end

  # Base makes several blocks in one second, so rows that share a second
  # follow the chain's own order.
  @newest_first [occurred_at: :desc, block_number: :desc, log_index: :desc, id: :asc]

  actions do
    read :recent do
      prepare build(sort: @newest_first, limit: 20, load: [:auction, :max_fdv])
      filter expr(occurred_at > ago(1, :hour))
    end

    read :for_auction do
      argument :auction_id, :uuid, allow_nil?: false
      filter expr(auction_id == ^arg(:auction_id))
      prepare build(sort: [block_number: :asc, log_index: :asc])
    end

    read :for_bid do
      get? true
      argument :auction_id, :uuid, allow_nil?: false
      argument :bid_id, :string, allow_nil?: false
      filter expr(auction_id == ^arg(:auction_id) and bid_id == ^arg(:bid_id))
    end

    create :record do
      accept [
        :auction_id,
        :bid_id,
        :bidder,
        :transaction_hash,
        :block_hash,
        :block_number,
        :log_index,
        :clock_block,
        :occurred_at,
        :amount,
        :display_amount,
        :display_symbol,
        :max_price
      ]

      upsert? true
      upsert_identity :auction_bid

      upsert_fields [
        :bidder,
        :transaction_hash,
        :block_hash,
        :block_number,
        :log_index,
        :clock_block,
        :occurred_at,
        :amount,
        :display_amount,
        :display_symbol,
        :max_price
      ]
    end
  end

  policies do
    policy action([:recent, :for_auction, :for_bid]) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :bid_id, :string, allow_nil?: false
    # The wallet that owns the bid, lowercase.
    attribute :bidder, :string, allow_nil?: false
    attribute :transaction_hash, :string, allow_nil?: false
    attribute :block_hash, :string, allow_nil?: false
    attribute :block_number, :integer, allow_nil?: false
    attribute :log_index, :integer, allow_nil?: false
    attribute :clock_block, :integer, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    attribute :amount, :decimal, allow_nil?: false, constraints: [min: 0]
    attribute :display_amount, :decimal, allow_nil?: false, constraints: [min: 0]
    attribute :display_symbol, :string, allow_nil?: false
    # The most the bid pays per token, in the auction's currency.
    attribute :max_price, :decimal, allow_nil?: false, constraints: [min: 0]
  end

  relationships do
    belongs_to :auction, Autolaunch.Auction do
      allow_nil? false
      read_action :listed
    end
  end

  calculations do
    # The bidder's price ceiling for the whole token: the bid's maximum price
    # times the token's total supply, liquidity share included, in the
    # auction's currency; nil until the auction's reading job has read the supply.
    calculate :max_fdv, :decimal, expr(max_price * auction.token_supply) do
      public? true
    end
  end

  identities do
    identity :auction_bid, [:auction_id, :bid_id]
  end
end
