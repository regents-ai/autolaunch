defmodule Autolaunch.BidOperation do
  @moduledoc """
  One durable bid the server owns before any wallet opens.

  The reviewed sequence is immutable and lives in `envelope`. `step` says which
  of its transactions is wallet-capable right now and `state` says how far the
  reviewed sequence has got. Every wallet press of a step is its own
  `WalletAttempt`; a confirmed press advances the step or ends the bid.

  `action_id` is unique. An account may hold any number of open reviews: each
  press is prepared as its own review, and one never cancels another. A review
  nobody sends lapses with its envelope.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # A direct bid needs at most the two allowances and the bid itself; a USDC bid
  # needs the exact USDC allowance to the adapter and the adapter call.
  @steps [:token_approval, :permit2_approval, :bid, :usdc_approval, :usdc_bid]
  @states [:prepared, :confirmed, :cancelled, :expired]

  postgres do
    table "bid_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    update :project_wallet_confirmation do
      accept [:step, :state, :terminal_at, :onchain_bid_id]
    end

    create :prepare do
      accept [:action_id, :envelope, :signer, :step]
      argument :human_account_id, :integer, allow_nil?: false
      change set_attribute(:human_account_id, arg(:human_account_id))
    end

    update :cancel do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :cancelled)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    # The granted Permit2 allowance has passed its expiry with no press still in
    # flight. The old sequence can no longer be spent, so a new review has to
    # reread current state rather than resume this one.
    update :expire do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :expired)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    # Never accepted by an update: the reviewed identity is the operation.
    attribute :action_id, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :envelope, :map, allow_nil?: false, sensitive?: true

    attribute :signer, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :step, :atom, allow_nil?: false, constraints: [one_of: @steps]
    attribute :state, :atom, allow_nil?: false, default: :prepared, constraints: [one_of: @states]

    # Adopted from the verified BidSubmitted event, never guessed before mining.
    attribute :onchain_bid_id, :string, constraints: [max_length: 78]

    attribute :reason, :string, constraints: [max_length: 120]
    attribute :terminal_at, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end
  end

  identities do
    identity :unique_action_id, [:action_id]
  end
end
