defmodule Autolaunch.RevenuePayment do
  @moduledoc """
  Confirmed payments into a Base Revstake launch's revenue split: one row per
  `PaymentRouted` its canonical payment receiver emitted, as
  `Autolaunch.RevenuePayments` reads them from the chain. No pending
  transactions; the chain is the record and these rows only follow it.

  `payer` is the account whose transfer into the receiver the same
  transaction carried, which is the paying wallet for a payment. A sweep
  routes a balance that was already waiting, so it names no payer.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "revenue_payments"
    repo Autolaunch.Repo

    custom_indexes do
      index [:auction_id, :block_number, :log_index]
    end
  end

  actions do
    read :recent_for_auction do
      argument :auction_id, :uuid, allow_nil?: false
      filter expr(auction_id == ^arg(:auction_id))
      prepare build(sort: [block_number: :desc, log_index: :desc], limit: 10)
    end

    create :record do
      accept [
        :auction_id,
        :chain_id,
        :receiver,
        :token,
        :token_symbol,
        :gross,
        :net,
        :payer,
        :payment_ref,
        :transaction_hash,
        :log_index,
        :block_number,
        :block_hash,
        :occurred_at
      ]

      upsert? true
      upsert_identity :chain_log

      upsert_fields [
        :auction_id,
        :receiver,
        :token,
        :token_symbol,
        :gross,
        :net,
        :payer,
        :payment_ref,
        :block_number,
        :block_hash,
        :occurred_at
      ]
    end
  end

  policies do
    policy action(:recent_for_auction) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :chain_id, :integer, allow_nil?: false, public?: true
    attribute :receiver, :string, allow_nil?: false, public?: true
    # The asset paid, lowercase, and its symbol at the time it was recorded.
    attribute :token, :string, allow_nil?: false, public?: true
    attribute :token_symbol, :string, allow_nil?: false, public?: true
    # Exact amounts in whole units: what was routed, and what reached the
    # splitter after the receiver's referral share (zero on this receiver).
    attribute :gross, :decimal, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :net, :decimal, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :payer, :string, public?: true
    attribute :payment_ref, :string, allow_nil?: false, public?: true
    attribute :transaction_hash, :string, allow_nil?: false, public?: true
    attribute :log_index, :integer, allow_nil?: false, public?: true
    attribute :block_number, :integer, allow_nil?: false, public?: true
    attribute :block_hash, :string, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :auction, Autolaunch.Auction do
      allow_nil? false
      read_action :listed
    end
  end

  identities do
    identity :chain_log, [:chain_id, :transaction_hash, :log_index]
  end
end
