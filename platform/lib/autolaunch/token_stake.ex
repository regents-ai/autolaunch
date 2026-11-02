defmodule Autolaunch.TokenStake do
  @moduledoc """
  Stakes in a launched token's splitter, one row per `Staked` log, written by
  `Autolaunch.TokenTrades` in the same pass and under the same cursor as the
  token's trades. The amount is in whole tokens. Each stake from a wallet that
  belonged to an account, or its paired agent, when it staked is offered to
  Regent Points (`autolaunch.token_staked`).
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "token_stakes"
    repo Autolaunch.Repo

    custom_indexes do
      index [:token_id, :block_number]
    end
  end

  actions do
    read :for_log do
      get? true
      argument :token_id, :uuid, allow_nil?: false
      argument :transaction_hash, :string, allow_nil?: false
      argument :log_index, :integer, allow_nil?: false

      filter expr(
               token_id == ^arg(:token_id) and transaction_hash == ^arg(:transaction_hash) and
                 log_index == ^arg(:log_index)
             )
    end

    create :record do
      accept [
        :token_id,
        :staker,
        :transaction_hash,
        :block_hash,
        :block_number,
        :log_index,
        :occurred_at,
        :amount
      ]

      upsert? true
      upsert_identity :splitter_log

      upsert_fields [
        :staker,
        :block_hash,
        :block_number,
        :occurred_at,
        :amount,
        :human_account_id,
        :pairing_id
      ]

      change {Autolaunch.Changes.FreezeWalletOwner, wallet: :staker, at: :occurred_at}

      emit Autolaunch.Signals, :token_staked,
        fields: [token_id: :token_id, transaction_hash: :transaction_hash, log_index: :log_index],
        where: [present(:human_account_id)]
    end
  end

  policies do
    policy action(:for_log) do
      authorize_if Autolaunch.Checks.SystemActor
    end

    policy action(:record) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    # The wallet that staked, lowercase.
    attribute :staker, :string, allow_nil?: false
    attribute :transaction_hash, :string, allow_nil?: false
    attribute :block_hash, :string, allow_nil?: false
    attribute :block_number, :integer, allow_nil?: false
    attribute :log_index, :integer, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    attribute :amount, :decimal, allow_nil?: false, constraints: [min: 0]

    # Who the wallet belonged to when the chain says it acted
    # (`Autolaunch.Changes.FreezeWalletOwner`): the account, and the pairing
    # when it was that person's agent. Nil when no one, or more than one, held it.
    attribute :human_account_id, :integer
    attribute :pairing_id, :uuid
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
