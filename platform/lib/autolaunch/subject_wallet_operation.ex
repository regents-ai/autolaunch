defmodule Autolaunch.SubjectWalletOperation do
  @moduledoc """
  One durable subject wallet operation the server owns before any wallet opens.

  The reviewed sequence is immutable and lives in `envelope`: at most an exact
  token approval followed by the one C1 call it enables. `step` says which of
  those two transactions is wallet-capable right now and `state` says how far
  that one transaction has got, so exactly one step is sendable at a time and its
  hash is bound before the next becomes so.

  The database decides every race. `action_id` is unique, each hash column is
  unique within itself across every operation, and a partial identity over
  `terminal_at IS NULL` allows one open operation per human account and subject
  — a different subject stays completely independent. A claimed step whose
  outcome is unknown holds that slot until the account explicitly ends it; it
  never becomes a fresh send, and a hash that arrives late attaches to the
  operation it belongs to without reopening it.

  The same hash cannot settle in the other phase either: verification matches the
  exact target and calldata that phase reviewed, so an approval hash offered as
  an action hash fails identity rather than confirming.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @kinds [:stake, :unstake, :claim, :claim_all, :pay, :sweep, :set_note]
  @steps [:approval, :action]
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

  @hashes [:approval_transaction_hash, :action_transaction_hash]

  # Postgres caps an index name at 63 bytes, so each identity is named for the
  # phase it protects rather than for the whole column.
  @hash_identities [
    {:unique_approval_hash, :approval_transaction_hash},
    {:unique_action_hash, :action_transaction_hash}
  ]

  postgres do
    table "subject_wallet_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
    end

    identity_wheres_to_sql one_open_per_subject: "terminal_at IS NULL"
  end

  actions do
    defaults [:read]

    update :project_wallet_confirmation do
      accept [:step, :state, :terminal_at, :result]
    end

    read :open do
      get? true
      argument :human_account_id, :integer, allow_nil?: false
      argument :subject_id, :string, allow_nil?: false

      filter expr(
               human_account_id == ^arg(:human_account_id) and
                 subject_id == ^arg(:subject_id) and is_nil(terminal_at)
             )
    end

    create :prepare do
      accept [:action_id, :subject_id, :kind, :envelope, :signer, :step]
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

    # The approval is verified, so the action it enables becomes sendable. The
    # approval's own hash stays exactly where it is.
    update :advance do
      accept []
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      validate attribute_equals(:step, :approval)
      change set_attribute(:step, :action)
      change set_attribute(:state, :prepared)
    end

    update :confirm do
      accept [:result]
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      validate attribute_equals(:step, :action)
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

    # The reviewed envelope has passed its expiry with no hash to report, so the
    # old bytes can no longer be spent and a new review has to reread state.
    update :expire do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :expired)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    # The account chose to start a new action while a claimed step's outcome is
    # still unknown. The calldata is never resent; the row stays for the
    # projector to reconcile and the account's slot for this subject is released.
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

    attribute :subject_id, :string, allow_nil?: false, constraints: [max_length: 128]
    attribute :kind, :atom, allow_nil?: false, constraints: [one_of: @kinds]
    attribute :envelope, :map, allow_nil?: false, sensitive?: true

    attribute :signer, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :step, :atom, allow_nil?: false, constraints: [one_of: @steps]
    attribute :state, :atom, allow_nil?: false, default: :prepared, constraints: [one_of: @states]

    for hash <- @hashes do
      attribute hash, :string, sensitive?: true, constraints: [min_length: 66, max_length: 66]
    end

    # Adopted from the verified event, never guessed before mining: the amounts a
    # claim or a sweep actually moved and the note a payment actually carried.
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
  end

  identities do
    identity :unique_action_id, [:action_id]

    for {name, hash} <- @hash_identities do
      identity name, [hash]
    end

    identity :one_open_per_subject, [:human_account_id, :subject_id] do
      where expr(is_nil(terminal_at))
    end
  end
end
