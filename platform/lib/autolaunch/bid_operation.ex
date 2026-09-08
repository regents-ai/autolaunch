defmodule Autolaunch.BidOperation do
  @moduledoc """
  One durable bid the server owns before any wallet opens.

  The reviewed sequence is immutable and lives in `envelope`. `step` says which
  of its transactions is wallet-capable right now and `state` says how far that
  one transaction has got, so exactly one step is sendable at a time and its hash
  is bound before the next becomes so.

  The database decides every race: `action_id` is unique, each hash column is
  unique within itself, and a partial identity over `terminal_at IS NULL`
  allows one open bid per account. A claimed step whose
  outcome is unknown holds that slot until the account explicitly ends it; it
  never becomes a fresh send, and a hash that arrives late attaches to the
  operation it belongs to without reopening it.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @steps [:token_approval, :permit2_approval, :bid]
  @states [
    :prepared,
    :dispatched,
    :submitted,
    :confirmed,
    :unverified,
    :reverted,
    :not_sent,
    :cancelled,
    :expired,
    :submission_unknown
  ]

  @hashes [
    :token_approval_transaction_hash,
    :permit2_approval_transaction_hash,
    :bid_transaction_hash
  ]

  postgres do
    table "bid_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
    end

    identity_wheres_to_sql one_open_per_account: "terminal_at IS NULL"
  end

  actions do
    defaults [:read]

    update :project_wallet_confirmation do
      accept [:step, :state, :terminal_at, :onchain_bid_id]
    end

    read :open do
      get? true
      argument :human_account_id, :integer, allow_nil?: false
      filter expr(human_account_id == ^arg(:human_account_id) and is_nil(terminal_at))
    end

    create :prepare do
      accept [:action_id, :envelope, :signer, :step]
      argument :human_account_id, :integer, allow_nil?: false
      change set_attribute(:human_account_id, arg(:human_account_id))
    end

    update :claim_dispatch do
      accept []
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :dispatched)
    end

    # The boundary derives which column from the row's own `step`, so a hash can
    # only ever land on the step that was claimed.
    update :bind_hash do
      accept @hashes
      require_atomic? false
      validate attribute_equals(:state, :dispatched)
      change set_attribute(:state, :submitted)
    end

    update :advance do
      accept [:step]
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      change set_attribute(:state, :prepared)
    end

    update :confirm do
      accept [:onchain_bid_id]
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      validate attribute_equals(:step, :bid)
      validate present(:onchain_bid_id)
      change set_attribute(:state, :confirmed)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    # A canonical success whose own logs or allowance contradict the review, and
    # a canonical revert. Both are terminal and neither is ever resent.
    update :record_unverified do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      change set_attribute(:state, :unverified)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    update :record_revert do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      change set_attribute(:state, :reverted)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    update :cancel do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :cancelled)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    # The exact EIP-1193 rejection of a claimed step: the wallet was asked and
    # said no, so nothing was broadcast.
    update :close_not_sent do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :dispatched)
      change set_attribute(:state, :not_sent)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    update :release_unstarted do
      accept []
      require_atomic? false
      validate attribute_equals(:state, :dispatched)
      change set_attribute(:state, :prepared)
    end

    # The granted Permit2 allowance has passed its expiry with no later hash to
    # report. The old sequence can no longer be spent, so a new review has to
    # reread current state rather than resume this one.
    update :expire do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :expired)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    # The account chose to start a new bid while a claimed step's outcome is
    # still unknown. The calldata is never resent; the row stays for the
    # projector to reconcile and the account's slot is released.
    update :close_submission_unknown do
      accept [:reason]
      require_atomic? false
      validate attribute_in(:state, [:dispatched, :submitted])
      change set_attribute(:state, :submission_unknown)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    # A hash recovered after the operation ended. It is attached so the same
    # transaction can still be verified truthfully, and the terminal state and
    # every hash already bound are left exactly as they were.
    update :attach_late_hash do
      accept @hashes
      require_atomic? false
      validate present(:terminal_at)
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

    for hash <- @hashes do
      attribute hash, :string, sensitive?: true, constraints: [min_length: 66, max_length: 66]
    end

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

    for hash <- @hashes do
      identity :"unique_#{hash}", [hash]
    end

    identity :one_open_per_account, [:human_account_id] do
      where expr(is_nil(terminal_at))
    end
  end
end
