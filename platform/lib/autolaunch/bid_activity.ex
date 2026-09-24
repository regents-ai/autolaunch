defmodule Autolaunch.BidActivity do
  @moduledoc "Confirmed public bid events. No wallet identities or pending transactions."
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

  actions do
    read :recent do
      prepare build(sort: [occurred_at: :desc, id: :asc], limit: 20, load: [:auction])
      filter expr(occurred_at > ago(1, :hour))
    end

    create :record do
      accept [
        :auction_id,
        :bid_id,
        :transaction_hash,
        :block_hash,
        :block_number,
        :occurred_at,
        :amount,
        :display_amount,
        :display_symbol
      ]

      upsert? true
      upsert_identity :auction_bid

      upsert_fields [
        :transaction_hash,
        :block_hash,
        :block_number,
        :occurred_at,
        :amount,
        :display_amount,
        :display_symbol
      ]
    end
  end

  policies do
    policy action(:recent) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :bid_id, :string, allow_nil?: false
    attribute :transaction_hash, :string, allow_nil?: false
    attribute :block_hash, :string, allow_nil?: false
    attribute :block_number, :integer, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    attribute :amount, :decimal, allow_nil?: false, constraints: [min: 0]
    attribute :display_amount, :decimal, allow_nil?: false, constraints: [min: 0]
    attribute :display_symbol, :string, allow_nil?: false
  end

  relationships do
    belongs_to :auction, Autolaunch.Auction do
      allow_nil? false
      read_action :listed
    end
  end

  identities do
    identity :auction_bid, [:auction_id, :bid_id]
  end
end
