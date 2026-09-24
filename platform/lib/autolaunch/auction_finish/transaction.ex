defmodule Autolaunch.AuctionFinish.Transaction do
  @moduledoc """
  One `migrate` transaction the finishing wallet signed, recorded and committed
  before it is broadcast.

  The signed bytes are kept, so a transaction the network never saw is sent
  again exactly as signed rather than replaced. A transaction stays `signed`
  until the chain settles it: `mined` or `reverted` by its receipt, or
  `dropped` when its nonce was used by another transaction. While one is
  `signed`, its launch is never sent another.

  The database holds both rules: one nonce per wallet on a chain, and at most
  one unsettled transaction per launch.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "auction_finish_transactions"
    repo Autolaunch.Repo

    references do
      reference :auction_finish, on_delete: :restrict
    end

    identity_index_names one_nonce_per_wallet: "auction_finish_transactions_nonce_index",
                         one_unsettled_per_launch: "auction_finish_transactions_unsettled_index"

    identity_wheres_to_sql one_unsettled_per_launch: "state = 'signed'"
  end

  actions do
    defaults [:read]

    read :unsettled do
      get? true
      argument :auction_finish_id, :uuid, allow_nil?: false
      filter expr(auction_finish_id == ^arg(:auction_finish_id) and state == :signed)
    end

    read :highest_nonce do
      get? true
      argument :chain_id, :integer, allow_nil?: false
      argument :signer, :string, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id) and signer == ^arg(:signer))
      prepare build(sort: [nonce: :desc], limit: 1)
    end

    create :record do
      accept [
        :auction_finish_id,
        :chain_id,
        :signer,
        :nonce,
        :transaction_hash,
        :raw_transaction
      ]
    end

    update :settle do
      require_atomic? false

      argument :outcome, :atom,
        allow_nil?: false,
        constraints: [one_of: [:mined, :reverted, :dropped]]

      validate attribute_equals(:state, :signed)
      change set_attribute(:state, arg(:outcome))
    end
  end

  policies do
    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :signer, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :nonce, :integer, allow_nil?: false, constraints: [min: 0]

    attribute :transaction_hash, :string,
      allow_nil?: false,
      constraints: [min_length: 66, max_length: 66]

    attribute :raw_transaction, :string, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :signed,
      constraints: [one_of: [:signed, :mined, :reverted, :dropped]]

    timestamps()
  end

  relationships do
    belongs_to :auction_finish, Autolaunch.AuctionFinish, allow_nil?: false
  end

  identities do
    identity :one_nonce_per_wallet, [:chain_id, :signer, :nonce]

    identity :one_unsettled_per_launch, [:auction_finish_id] do
      where expr(state == :signed)
    end
  end
end
