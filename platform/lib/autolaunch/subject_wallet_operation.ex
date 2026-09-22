defmodule Autolaunch.SubjectWalletOperation do
  @moduledoc """
  One durable subject wallet operation the server owns before any wallet opens.

  The reviewed sequence is immutable and lives in `envelope`: at most an exact
  token approval followed by the one C1 call it enables. `step` says which of
  those two transactions is wallet-capable right now and `state` says how far
  the reviewed sequence has got. Every wallet press of a step is its own
  `WalletAttempt`; a confirmed approval makes the action sendable and a
  confirmed action ends the operation.

  The database decides every race. `action_id` is unique and a partial identity
  over `terminal_at IS NULL` allows one open operation per human account and
  subject — a different subject stays completely independent.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @kinds [:stake, :unstake, :claim, :claim_all, :pay, :sweep, :set_note]
  @steps [:approval, :action]
  @states [:prepared, :confirmed, :cancelled, :expired]

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

    update :cancel do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :cancelled)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    # The reviewed envelope has passed its expiry with no press still in flight,
    # so the old bytes can no longer be spent and a new review has to reread
    # state.
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

    attribute :subject_id, :string, allow_nil?: false, constraints: [max_length: 128]
    attribute :kind, :atom, allow_nil?: false, constraints: [one_of: @kinds]
    attribute :envelope, :map, allow_nil?: false, sensitive?: true

    attribute :signer, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :step, :atom, allow_nil?: false, constraints: [one_of: @steps]
    attribute :state, :atom, allow_nil?: false, default: :prepared, constraints: [one_of: @states]

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

    identity :one_open_per_subject, [:human_account_id, :subject_id] do
      where expr(is_nil(terminal_at))
    end
  end
end
