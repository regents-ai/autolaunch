defmodule Autolaunch.Stocks.FeeAdminOperation do
  @moduledoc """
  One durable fee-administration action on a Stocks launch, owned by the server
  before any wallet opens.

  Three actions share this one lane: `configure_subject` turns the subject
  revenue lane on, off or onto another splitter (`configureSubject`),
  `propose_administrator` starts handing the administrator role over
  (`proposeFeeAdministrator`), and `accept_administrator` completes that hand-over
  from the proposed wallet (`acceptFeeAdministrator`). Each is exactly one
  transaction, so the reviewed sequence in `envelope` has one `action` step.

  The database decides every race exactly as the other wallet lanes do:
  `action_id` is unique, the hash column is unique, and a partial identity over
  `terminal_at IS NULL` allows one open operation per human account and auction.
  A stale configuration version is not caught here or at dispatch: the contract
  refuses it and the wallet reports the revert.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @kinds [:configure_subject, :propose_administrator, :accept_administrator]
  @steps [:action]
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

  postgres do
    table "stock_fee_admin_operations"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
      reference :auction, on_delete: :restrict
    end

    identity_wheres_to_sql one_open_per_auction: "terminal_at IS NULL"

    identity_index_names unique_action_id: "stock_fee_admin_operations_action_id_index",
                         unique_action_hash: "stock_fee_admin_operations_hash_index",
                         one_open_per_auction: "stock_fee_admin_operations_one_open_index"
  end

  actions do
    defaults [:read]

    update :project_wallet_confirmation do
      accept [:step, :state, :terminal_at, :result]
    end

    read :open do
      get? true
      argument :human_account_id, :integer, allow_nil?: false
      argument :auction_id, :uuid, allow_nil?: false

      filter expr(
               human_account_id == ^arg(:human_account_id) and
                 auction_id == ^arg(:auction_id) and is_nil(terminal_at)
             )
    end

    create :prepare do
      accept [:action_id, :kind, :envelope, :signer, :step]
      argument :human_account_id, :integer, allow_nil?: false
      argument :auction_id, :uuid, allow_nil?: false
      change set_attribute(:human_account_id, arg(:human_account_id))
      change set_attribute(:auction_id, arg(:auction_id))
    end

    update :claim_dispatch do
      accept []
      require_atomic? false
      validate attribute_equals(:state, :prepared)
      change set_attribute(:state, :dispatched)
    end

    update :bind_hash do
      accept [:action_transaction_hash]
      require_atomic? false
      validate attribute_equals(:state, :dispatched)
      change set_attribute(:state, :submitted)
    end

    update :confirm do
      accept [:result]
      require_atomic? false
      validate attribute_equals(:state, :submitted)
      change set_attribute(:state, :confirmed)
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
      accept [:action_transaction_hash]
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

    attribute :kind, :atom, allow_nil?: false, constraints: [one_of: @kinds]
    attribute :envelope, :map, allow_nil?: false, sensitive?: true

    attribute :signer, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :step, :atom, allow_nil?: false, default: :action, constraints: [one_of: @steps]
    attribute :state, :atom, allow_nil?: false, default: :prepared, constraints: [one_of: @states]

    attribute :action_transaction_hash, :string,
      sensitive?: true,
      constraints: [min_length: 66, max_length: 66]

    # Adopted from the verified event and the configuration read back after it.
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

    belongs_to :auction, Autolaunch.Auction do
      allow_nil? false
    end
  end

  identities do
    identity :unique_action_id, [:action_id]
    identity :unique_action_hash, [:action_transaction_hash]

    identity :one_open_per_auction, [:human_account_id, :auction_id] do
      where expr(is_nil(terminal_at))
    end
  end
end
