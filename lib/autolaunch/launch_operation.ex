defmodule Autolaunch.LaunchOperation do
  @moduledoc """
  One durable direct-wallet launch the server owns before any wallet opens.

  The reviewed sequence is immutable and lives in `envelope`: at most an exact
  REGENT allowance correction followed by the one `launch` call it enables.
  `step` says which of those two transactions is wallet-capable right now and
  `state` says how far that one transaction has got, so exactly one step is
  sendable at a time and its hash is bound before the next becomes so.

  The database decides every race. `action_id` is unique, each hash column is
  unique within itself across every operation, and a partial identity over
  `terminal_at IS NULL` allows one open launch per human account. A new prepare
  closes whatever is open as replaced and takes the slot; a closed step never
  becomes a fresh send, and a hash that arrives late attaches to the operation
  it belongs to without reopening it.

  `chain_verified` is the honest terminal success: this server proved its own
  receipt evidence. Canonical public launch confirmation is the finalized
  `490.8.2` projection and is deliberately not named here.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @steps [:approval, :launch]
  @states [
    :prepared,
    :dispatched,
    :submitted,
    :chain_verified,
    :unverified,
    :reverted,
    :not_sent,
    :cancelled,
    :expired,
    :invalidated,
    :submission_unknown
  ]

  @hashes [:approval_transaction_hash, :launch_transaction_hash]

  # Postgres caps an index name at 63 bytes, so each identity is named for the
  # phase it protects rather than for the whole column.
  @hash_identities [
    {:unique_launch_approval_hash, :approval_transaction_hash},
    {:unique_launch_hash, :launch_transaction_hash}
  ]

  postgres do
    table "launch_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
      reference :launch_draft, on_delete: :restrict
    end

    identity_wheres_to_sql one_open_per_account: "terminal_at IS NULL"
  end

  actions do
    defaults [:read]

    read :open do
      get? true
      argument :human_account_id, :integer, allow_nil?: false
      filter expr(human_account_id == ^arg(:human_account_id) and is_nil(terminal_at))
    end

    read :chain_verified_by_launch_hash do
      get? true
      argument :launch_transaction_hash, :string, allow_nil?: false

      filter expr(
               state == :chain_verified and
                 fragment("lower(?)", launch_transaction_hash) ==
                   fragment("lower(?)", ^arg(:launch_transaction_hash))
             )
    end

    create :prepare do
      accept [:action_id, :envelope, :signer, :step]
      argument :human_account_id, :integer, allow_nil?: false
      argument :launch_draft_id, :uuid, allow_nil?: false
      validate Autolaunch.LaunchOperation.Validations.AuctionLimit
      change set_attribute(:human_account_id, arg(:human_account_id))
      change set_attribute(:launch_draft_id, arg(:launch_draft_id))
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

    # The allowance correction is verified, so the launch it enables becomes
    # sendable. The approval's own hash stays exactly where it is.
    update :advance do
      accept [:result]
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      validate attribute_equals(:step, :approval)
      change set_attribute(:step, :launch)
      change set_attribute(:state, :prepared)
    end

    update :record_chain_verified do
      accept [:result]
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      validate attribute_equals(:step, :launch)
      change set_attribute(:state, :chain_verified)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    # A canonical success whose own logs or factory reads contradict the review,
    # and a canonical revert. Both are terminal and neither is ever resent.
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

    # Base disagreed with the review before this step was ever handed to a
    # wallet, so the reviewed bytes can no longer be spent at all.
    update :invalidate do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :invalidated)
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

    # The reviewed envelope has passed its expiry with no hash to report, so the
    # old bytes can no longer be spent and a new review has to reread state.
    update :expire do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :expired)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    # The account chose to start a new launch while a claimed step's outcome is
    # still unknown. The calldata is never resent; the row stays for the
    # projector to reconcile and the account's open slot is released.
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

    # Adopted from the verified `LaunchCreated`, never guessed before mining: the
    # launch id, subject, auction, escrow and the fixed schedule it recorded.
    attribute :result, :map, default: %{}

    attribute :reason, :string, constraints: [max_length: 120]
    attribute :terminal_at, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end

    belongs_to :launch_draft, Autolaunch.LaunchDraft do
      allow_nil? false
    end
  end

  identities do
    identity :unique_launch_action_id, [:action_id]

    for {name, hash} <- @hash_identities do
      identity name, [hash]
    end

    identity :one_open_per_account, [:human_account_id] do
      where expr(is_nil(terminal_at))
    end
  end
end
