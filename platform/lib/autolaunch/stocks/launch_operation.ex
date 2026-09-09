defmodule Autolaunch.Stocks.LaunchOperation do
  @moduledoc """
  One durable direct-wallet Stocks launch the server owns before any wallet opens.

  The reviewed sequence is immutable and lives in `envelope`: exactly one
  `launch` call to the Stocks launchpad. There is no fee and no allowance step.
  `state` says how far that one transaction has got.

  The database decides every race exactly as for the Agent launch: `action_id`
  is unique, the launch hash is unique, and a partial identity over
  `terminal_at IS NULL` allows one open Stocks launch per human account.
  `chain_verified` means this server proved its own receipt evidence.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @steps [:launch]
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

  postgres do
    table "stock_launch_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
      reference :launch_draft, on_delete: :restrict
    end

    identity_wheres_to_sql one_open_per_account: "terminal_at IS NULL"

    identity_index_names unique_action_id: "stock_launch_operations_action_id_index",
                         unique_hash: "stock_launch_operations_hash_index",
                         one_open_per_account: "stock_launch_operations_one_open_index"
  end

  actions do
    defaults [:read]

    update :project_wallet_confirmation do
      accept [:step, :state, :terminal_at, :result]
    end

    read :open do
      get? true
      argument :human_account_id, :integer, allow_nil?: false
      filter expr(human_account_id == ^arg(:human_account_id) and is_nil(terminal_at))
    end

    # The one verified launch that created an auction, so a projected Stocks
    # auction names the account whose wallet this server proved sent it.
    read :chain_verified_by_auction do
      get? true
      argument :auction_address, :string, allow_nil?: false

      filter expr(
               state == :chain_verified and
                 fragment("lower(? ->> 'auction')", result) ==
                   fragment("lower(?)", ^arg(:auction_address))
             )
    end

    create :prepare do
      accept [:action_id, :envelope, :signer, :step]
      argument :human_account_id, :integer, allow_nil?: false
      argument :launch_draft_id, :uuid, allow_nil?: false
      change set_attribute(:human_account_id, arg(:human_account_id))
      change set_attribute(:launch_draft_id, arg(:launch_draft_id))
    end

    update :claim_dispatch do
      accept []
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :dispatched)
    end

    update :bind_hash do
      accept [:launch_transaction_hash]
      require_atomic? false
      validate attribute_equals(:state, :dispatched)
      change set_attribute(:state, :submitted)
    end

    update :record_chain_verified do
      accept [:result]
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      change set_attribute(:state, :chain_verified)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

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

    update :invalidate do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :invalidated)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

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

    update :expire do
      accept [:reason]
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :expired)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    update :close_submission_unknown do
      accept [:reason]
      require_atomic? false
      validate attribute_in(:state, [:dispatched, :submitted])
      change set_attribute(:state, :submission_unknown)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
    end

    update :attach_late_hash do
      accept [:launch_transaction_hash]
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

    attribute :action_id, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :envelope, :map, allow_nil?: false, sensitive?: true

    attribute :signer, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :step, :atom, allow_nil?: false, default: :launch, constraints: [one_of: @steps]
    attribute :state, :atom, allow_nil?: false, default: :prepared, constraints: [one_of: @states]

    attribute :launch_transaction_hash, :string,
      sensitive?: true,
      constraints: [min_length: 66, max_length: 66]

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
    identity :unique_hash, [:launch_transaction_hash]

    identity :one_open_per_account, [:human_account_id] do
      where expr(is_nil(terminal_at))
    end
  end
end
