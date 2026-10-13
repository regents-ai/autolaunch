defmodule Autolaunch.BidSettlement do
  @moduledoc """
  Confirmed public withdraws and claims: each auction's own `BidExited` and
  `TokensClaimed` events, read by the same chain watcher pass as the bids
  (`Autolaunch.AuctionActivity`) and replaced with them, whoever sent them.
  No pending transactions.

  A withdraw states the auction currency that came back and the launch tokens
  the bid filled; a claim states the tokens it delivered.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "bid_settlements"
    repo Autolaunch.Repo

    # The chain position identity's unique index serves the watcher's range
    # deletes; this one serves a bid's own page.
    custom_indexes do
      index [:auction_id, :bid_id]
    end
  end

  actions do
    read :for_bid do
      argument :auction_id, :uuid, allow_nil?: false
      argument :bid_id, :string, allow_nil?: false
      filter expr(auction_id == ^arg(:auction_id) and bid_id == ^arg(:bid_id))
      prepare build(sort: [block_number: :asc, log_index: :asc])
    end

    create :record do
      accept [
        :auction_id,
        :bid_id,
        :kind,
        :owner,
        :transaction_hash,
        :block_hash,
        :block_number,
        :log_index,
        :occurred_at,
        :currency,
        :tokens
      ]

      upsert? true
      upsert_identity :chain_position

      upsert_fields [
        :bid_id,
        :kind,
        :owner,
        :transaction_hash,
        :block_hash,
        :occurred_at,
        :currency,
        :tokens
      ]
    end
  end

  policies do
    policy action(:for_bid) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    # The auction's own id for the bid.
    attribute :bid_id, :string, allow_nil?: false, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:exit, :claim]
    end

    # The wallet that owns the bid, lowercase.
    attribute :owner, :string, allow_nil?: false, public?: true
    attribute :transaction_hash, :string, allow_nil?: false, public?: true
    attribute :block_hash, :string, allow_nil?: false
    attribute :block_number, :integer, allow_nil?: false
    attribute :log_index, :integer, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    # A withdraw's currency returned, in the auction's currency; nil on a claim.
    attribute :currency, :decimal, public?: true, constraints: [min: 0]
    # A withdraw's tokens filled, or a claim's tokens delivered.
    attribute :tokens, :decimal, allow_nil?: false, public?: true, constraints: [min: 0]
  end

  relationships do
    belongs_to :auction, Autolaunch.Auction do
      allow_nil? false
      read_action :listed
    end
  end

  identities do
    identity :chain_position, [:auction_id, :block_number, :log_index]
  end
end
