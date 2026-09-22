defmodule Autolaunch.BidSettlementOperation do
  @moduledoc """
  One durable settlement of one bid position after its auction has ended.

  The reviewed sequence is immutable and lives in `envelope`: an `exit` step
  (`exitBid`, or `exitPartiallyFilledBid` with derived checkpoint hints) that
  returns the unspent currency and records the fill, then, on a graduated
  auction with fill, a `claim` step (`claimTokens`) that delivers the launch
  token. A failed auction has only the `exit` step. `step` says which of those
  is wallet-capable right now and `state` how far the reviewed sequence has
  got. Every wallet press of a step is its own `WalletAttempt`.

  The database decides every race exactly as `BidOperation` does: `action_id`
  is unique and a partial identity over `terminal_at IS NULL` allows one open
  settlement per bid position.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @steps [:exit, :claim]
  @states [:prepared, :confirmed, :cancelled, :expired]

  postgres do
    table "bid_settlement_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
      reference :bid_position, on_delete: :restrict
    end

    identity_wheres_to_sql one_open_per_position: "terminal_at IS NULL"
  end

  actions do
    defaults [:read]

    update :project_wallet_confirmation do
      accept [:step, :state, :terminal_at, :result]
    end

    read :open do
      get? true
      argument :bid_position_id, :uuid, allow_nil?: false
      filter expr(bid_position_id == ^arg(:bid_position_id) and is_nil(terminal_at))
    end

    create :prepare do
      accept [:action_id, :envelope, :signer, :step]
      argument :human_account_id, :integer, allow_nil?: false
      argument :bid_position_id, :uuid, allow_nil?: false
      change set_attribute(:human_account_id, arg(:human_account_id))
      change set_attribute(:bid_position_id, arg(:bid_position_id))
    end

    update :cancel do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :cancelled)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

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

    attribute :action_id, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :envelope, :map, allow_nil?: false, sensitive?: true

    attribute :signer, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :step, :atom, allow_nil?: false, constraints: [one_of: @steps]
    attribute :state, :atom, allow_nil?: false, default: :prepared, constraints: [one_of: @states]

    # Adopted from the verified `BidExited` and `TokensClaimed` events, never
    # guessed before mining: `currency_refunded`, `tokens_filled`, `tokens_claimed`.
    attribute :result, :map, allow_nil?: false, default: %{}

    attribute :reason, :string, constraints: [max_length: 120]
    attribute :terminal_at, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end

    belongs_to :bid_position, Autolaunch.Bid do
      allow_nil? false
    end
  end

  identities do
    identity :unique_action_id, [:action_id]

    identity :one_open_per_position, [:bid_position_id] do
      where expr(is_nil(terminal_at))
    end
  end
end
