defmodule Autolaunch.Bid do
  alias Autolaunch.BidIdentity

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "bids"
    repo Autolaunch.Repo

    custom_indexes do
      index [:owner_address]
      index [:auction_id]
      index [:status]
    end
  end

  actions do
    read :mine do
      prepare build(sort: [inserted_at: :desc, id: :desc], load: [:auction, :token])
    end

    read :returnable_mine do
      filter expr(status == "returnable")

      prepare build(
                sort: [updated_at: :desc, inserted_at: :desc, id: :desc],
                load: [:auction, :token]
              )
    end

    read :claimable_mine do
      filter expr(status == "claimable")

      prepare build(
                sort: [updated_at: :desc, inserted_at: :desc, id: :desc],
                load: [:auction, :token]
              )
    end

    read :claimed_mine do
      filter expr(status == "claimed")

      prepare build(
                sort: [claimed_at: :desc_nils_last, inserted_at: :desc, id: :desc],
                load: [:auction, :token]
              )
    end

    read :owned_by_bid_id do
      get? true
      argument :bid_id, :string, allow_nil?: false, constraints: BidIdentity.constraints()
      filter expr(bid_id == ^arg(:bid_id))
      prepare build(load: [:auction, :token])
    end

    create :import_position do
      accept [
        :bid_id,
        :auction_id,
        :owner_address,
        :amount,
        :max_price,
        :current_clearing_price,
        :estimated_tokens_if_end_now,
        :status,
        :exited_at,
        :claimed_at
      ]

      change Autolaunch.Bid.Changes.NormalizeOwnerAddress
    end

    create :project_lab do
      accept [
        :bid_id,
        :auction_id,
        :owner_address,
        :amount,
        :max_price,
        :current_clearing_price,
        :estimated_tokens_if_end_now,
        :status,
        :exited_at,
        :claimed_at,
        :auction_address,
        :onchain_bid_id,
        :currency_refunded,
        :tokens_filled,
        :tokens_claimed
      ]

      change Autolaunch.Bid.Changes.NormalizeOwnerAddress
      upsert? true
      upsert_identity :unique_bid_id

      upsert_fields [
        :auction_id,
        :owner_address,
        :amount,
        :max_price,
        :current_clearing_price,
        :estimated_tokens_if_end_now,
        :status,
        :exited_at,
        :claimed_at,
        :auction_address,
        :onchain_bid_id,
        :currency_refunded,
        :tokens_filled,
        :tokens_claimed
      ]
    end

    update :set_chain_identity do
      require_atomic? false
      accept [:auction_address, :onchain_bid_id]
    end
  end

  policies do
    policy action([:mine, :returnable_mine, :claimable_mine, :claimed_mine, :owned_by_bid_id]) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
    end

    policy action([:mine, :returnable_mine, :claimable_mine, :claimed_mine, :owned_by_bid_id]) do
      authorize_if Autolaunch.Bid.Checks.VerifiedWalletOwner
    end

    policy action([:import_position, :project_lab, :set_chain_identity]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id, public?: false

    attribute :bid_id, :string do
      allow_nil? false
      public? true
      constraints BidIdentity.constraints()
    end

    attribute :owner_address, :string do
      allow_nil? false
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    attribute :amount, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100, trim?: true
    end

    attribute :max_price, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :current_clearing_price, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :estimated_tokens_if_end_now, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :status, :string do
      allow_nil? false
      public? true
      default "active"
      constraints min_length: 1, max_length: 100, trim?: true
    end

    attribute :exited_at, :utc_datetime_usec do
      public? true
    end

    attribute :claimed_at, :utc_datetime_usec do
      public? true
    end

    attribute :auction_address, :string do
      public? true
      constraints min_length: 42, max_length: 42, match: ~r/\A0x[0-9a-fA-F]{40}\z/
    end

    attribute :onchain_bid_id, :string do
      public? true
      constraints min_length: 1, max_length: 78, trim?: true, match: ~r/\A\d+\z/
    end

    # Settlement amounts, adopted from the auction's own `BidExited` and
    # `TokensClaimed` events: the currency returned (in the auction's currency
    # units), the launch tokens the bid filled, and the tokens claimed.
    attribute :currency_refunded, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :tokens_filled, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :tokens_claimed, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    timestamps()
  end

  relationships do
    belongs_to :auction, Autolaunch.Auction do
      allow_nil? false
      attribute_public? true
    end

    has_one :token, Autolaunch.Token do
      source_attribute :auction_id
      destination_attribute :auction_id
    end
  end

  identities do
    identity :unique_bid_id, [:bid_id]
  end
end
