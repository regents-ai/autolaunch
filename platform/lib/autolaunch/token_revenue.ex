defmodule Autolaunch.TokenRevenue do
  @moduledoc """
  Revenue a Revstake token's splitter recognized, one row per
  `RevenueRecognized` log, written by `Autolaunch.TokenTrades` in the same
  pass and under the same cursor as the token's trades. The amount is the
  gross the splitter took in, in its own asset (USDC, REGENT or the launch
  token); the stakers' share is the part that went to stakers.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "token_revenues"
    repo Autolaunch.Repo

    custom_indexes do
      index [:token_id, :block_number]
    end
  end

  actions do
    # A token's revenue, newest first, at most the latest fifty.
    read :for_token do
      argument :token_id, :uuid, allow_nil?: false
      filter expr(token_id == ^arg(:token_id))
      prepare build(sort: [block_number: :desc, log_index: :desc], limit: 50)
    end

    create :record do
      accept [
        :token_id,
        :transaction_hash,
        :block_hash,
        :block_number,
        :log_index,
        :occurred_at,
        :asset_symbol,
        :amount,
        :staker_share
      ]

      upsert? true
      upsert_identity :splitter_log

      upsert_fields [
        :block_hash,
        :block_number,
        :occurred_at,
        :asset_symbol,
        :amount,
        :staker_share
      ]
    end
  end

  policies do
    policy action(:for_token) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :transaction_hash, :string, allow_nil?: false
    attribute :block_hash, :string, allow_nil?: false
    attribute :block_number, :integer, allow_nil?: false
    attribute :log_index, :integer, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    # USDC, REGENT or the launch token's own symbol.
    attribute :asset_symbol, :string, allow_nil?: false
    attribute :amount, :decimal, allow_nil?: false, constraints: [min: 0]
    attribute :staker_share, :decimal, allow_nil?: false, constraints: [min: 0]
  end

  relationships do
    belongs_to :token, Autolaunch.Token do
      allow_nil? false
      read_action :listed
    end
  end

  identities do
    identity :splitter_log, [:token_id, :transaction_hash, :log_index]
  end
end
