defmodule Autolaunch.Stocks.LaunchOperation do
  @moduledoc """
  One durable direct-wallet Stocks launch the server owns before any wallet opens.

  The reviewed sequence is immutable and lives in `envelope`: the one `launch`
  call to the Stocks launchpad. `step` names that transaction and `state` says
  how far it has got.

  `action_id` is unique. An account may hold any number of open Stocks launch
  reviews, exactly as for the Agent launch: one never cancels another, and a
  review nobody sends lapses with its envelope. Every wallet press of the review is its own
  `WalletAttempt`; `chain_verified` means this server proved its own receipt
  evidence.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @steps [:launch]
  @states [:prepared, :chain_verified, :cancelled, :expired, :invalidated]

  postgres do
    table "stock_launch_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
      reference :launch_draft, on_delete: :restrict
    end

    identity_index_names unique_action_id: "stock_launch_operations_action_id_index"
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

    update :invalidate do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :invalidated)
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

    # Adopted from the verified `StockLaunchCreated`, never guessed before mining.
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

    belongs_to :launch_draft, Autolaunch.Stocks.LaunchDraft do
      allow_nil? false
    end
  end

  identities do
    identity :unique_action_id, [:action_id]
  end
end
