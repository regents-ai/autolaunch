defmodule Autolaunch.TokenTrade do
  @moduledoc """
  Confirmed trades in a launched token's pool, one row per `Swap` log, written
  by `Autolaunch.TokenTrades`. A buy took the token out of the pool and a sell
  put it in. The currency amount is the pool's other side, in its own
  currency: REGENT for a Revstake token, the paired stock for a Memestake one.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "token_trades"
    repo Autolaunch.Repo

    custom_indexes do
      index [:token_id, :block_number]
      index ["occurred_at DESC", "id"], name: "token_trades_recent_index"
    end
  end

  actions do
    read :recent do
      prepare build(sort: [occurred_at: :desc, id: :asc], limit: 20, load: [token: :auction])
      filter expr(occurred_at > ago(1, :hour))
    end

    create :record do
      accept [
        :token_id,
        :transaction_hash,
        :block_hash,
        :block_number,
        :log_index,
        :occurred_at,
        :side,
        :currency_amount,
        :currency_symbol,
        :token_amount
      ]

      upsert? true
      upsert_identity :pool_log

      upsert_fields [
        :block_hash,
        :block_number,
        :occurred_at,
        :side,
        :currency_amount,
        :currency_symbol,
        :token_amount
      ]
    end
  end

  policies do
    policy action(:recent) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  # A new trade reloads the ticker; see `Autolaunch.TokenTrades.subscribe/0`.
  pub_sub do
    module Phoenix.PubSub
    name Autolaunch.PubSub
    transform fn notification -> {:autolaunch_trade, notification.data.token_id} end

    publish :record, "token_trades"
  end

  attributes do
    uuid_primary_key :id
    attribute :transaction_hash, :string, allow_nil?: false
    attribute :block_hash, :string, allow_nil?: false
    attribute :block_number, :integer, allow_nil?: false
    attribute :log_index, :integer, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    attribute :side, :atom, allow_nil?: false, constraints: [one_of: [:buy, :sell]]
    # The pool's other side: what the buyer paid or the seller received.
    attribute :currency_amount, :decimal, allow_nil?: false, constraints: [greater_than: 0]
    attribute :currency_symbol, :string, allow_nil?: false
    attribute :token_amount, :decimal, allow_nil?: false, constraints: [greater_than: 0]
  end

  relationships do
    # Read through the listing rule, so a Robinhood launch's token is found too.
    belongs_to :token, Autolaunch.Token do
      allow_nil? false
      read_action :listed
    end
  end

  identities do
    identity :pool_log, [:token_id, :transaction_hash, :log_index]
  end
end
