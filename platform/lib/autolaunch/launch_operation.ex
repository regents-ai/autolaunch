defmodule Autolaunch.LaunchOperation do
  @moduledoc """
  One durable direct-wallet launch the server owns before any wallet opens.

  The reviewed sequence is immutable and lives in `envelope`: the one `launch`
  call. `step` names that transaction and `state` says how far it has got.

  `action_id` is unique. An account may hold any number of open launch reviews:
  each press is prepared as its own review, and one never cancels another. A
  review nobody sends lapses with its envelope. Every wallet press of the review
  is its own `WalletAttempt`; the operation only summarises how far the reviewed
  sequence has got.

  `chain_verified` is the honest terminal success: this server proved its own
  receipt evidence. Canonical public launch confirmation is the finalized
  `490.8.2` projection and is deliberately not named here.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @steps [:launch]
  @states [:prepared, :chain_verified, :cancelled, :expired, :invalidated]

  postgres do
    table "launch_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
      reference :launch_draft, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    update :project_wallet_confirmation do
      accept [:step, :state, :terminal_at, :result]
    end

    create :prepare do
      accept [:action_id, :envelope, :signer, :step]
      argument :human_account_id, :integer, allow_nil?: false
      argument :launch_draft_id, :uuid, allow_nil?: false
      validate Autolaunch.LaunchOperation.Validations.AuctionLimit
      change set_attribute(:human_account_id, arg(:human_account_id))
      change set_attribute(:launch_draft_id, arg(:launch_draft_id))
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

    attribute :envelope, :map, allow_nil?: false, sensitive?: true

    attribute :signer, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :step, :atom, allow_nil?: false, constraints: [one_of: @steps]
    attribute :state, :atom, allow_nil?: false, default: :prepared, constraints: [one_of: @states]

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
  end
end
