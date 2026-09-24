defmodule Autolaunch.WalletAttempt do
  @moduledoc "One immutable authorized wallet press, independent of its review and sibling presses."
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "wallet_attempts"
    repo Autolaunch.Repo

    references do
      reference :bid_operation, on_delete: :restrict
      reference :launch_operation, on_delete: :restrict
      reference :stock_launch_operation, on_delete: :restrict
      reference :bid_settlement_operation, on_delete: :restrict
    end

    custom_indexes do
      index [:bid_operation_id, :inserted_at]
      index [:launch_operation_id, :inserted_at]
      index [:stock_launch_operation_id, :inserted_at]
      index [:bid_settlement_operation_id, :inserted_at]
      index [:transaction_hash, :step, :state]
    end

    check_constraints do
      check_constraint :step, "wallet_attempt_parent_step",
        check:
          "(bid_operation_id IS NOT NULL AND launch_operation_id IS NULL AND stock_launch_operation_id IS NULL AND bid_settlement_operation_id IS NULL AND step IN ('token_approval','permit2_approval','bid','usdc_approval','usdc_bid')) OR (bid_operation_id IS NULL AND launch_operation_id IS NOT NULL AND stock_launch_operation_id IS NULL AND bid_settlement_operation_id IS NULL AND step IN ('approval','launch')) OR (bid_operation_id IS NULL AND launch_operation_id IS NULL AND stock_launch_operation_id IS NOT NULL AND bid_settlement_operation_id IS NULL AND step IN ('approval','launch')) OR (bid_operation_id IS NULL AND launch_operation_id IS NULL AND stock_launch_operation_id IS NULL AND bid_settlement_operation_id IS NOT NULL AND step IN ('exit','claim'))"
    end
  end

  actions do
    defaults [:read]

    create :dispatch do
      accept [
        :id,
        :bid_operation_id,
        :launch_operation_id,
        :stock_launch_operation_id,
        :bid_settlement_operation_id,
        :step,
        :envelope,
        :state,
        :transaction_hash
      ]
    end

    update :report do
      accept [:transaction_hash, :state, :result, :evidence, :resolved_at]
    end
  end

  policies do
    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :step, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :token_approval,
          :permit2_approval,
          :bid,
          :usdc_approval,
          :usdc_bid,
          :approval,
          :launch,
          :exit,
          :claim
        ]
      ]

    attribute :envelope, :map, allow_nil?: false, sensitive?: true

    attribute :state, :atom,
      allow_nil?: false,
      default: :dispatched,
      constraints: [
        one_of: [
          :dispatched,
          :submitted,
          :confirmed,
          :reverted,
          :unverified,
          :not_sent,
          :not_started,
          :submission_unknown
        ]
      ]

    attribute :transaction_hash, :string, constraints: [min_length: 66, max_length: 66]
    attribute :result, :map, allow_nil?: false, default: %{}
    attribute :evidence, :map, allow_nil?: false, default: %{}
    attribute :resolved_at, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :bid_operation, Autolaunch.BidOperation
    belongs_to :launch_operation, Autolaunch.LaunchOperation
    belongs_to :stock_launch_operation, Autolaunch.Stocks.LaunchOperation
    belongs_to :bid_settlement_operation, Autolaunch.BidSettlementOperation
  end
end
