defmodule Autolaunch.TokenTrade do
  @moduledoc """
  Confirmed trades in a launched token's pool, one row per `Swap` log, written
  by `Autolaunch.TokenTrades`. A buy took the token out of the pool and a sell
  put it in. The currency amount is the pool's other side, in its own
  currency: REGENT for a Revstake token, the paired stock for a Memestock one.

  The trader is the wallet that sent the swap's transaction, written with the
  row and never changed by a later write of it, so the reader asks the node
  only for trades not saved yet. Rows saved before the site recorded traders
  have none.
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

  # Base makes several blocks in one second, so rows that share a second
  # follow the chain's own order.
  @newest_first [occurred_at: :desc, block_number: :desc, log_index: :desc, id: :asc]

  actions do
    read :recent do
      prepare build(sort: @newest_first, limit: 20, load: [token: :auction])
      filter expr(occurred_at > ago(1, :hour))
    end

    # Every trade in one token's pool, in chain order.
    read :for_token do
      argument :token_id, :uuid, allow_nil?: false
      filter expr(token_id == ^arg(:token_id))
      prepare build(sort: [block_number: :asc, log_index: :asc])
    end

    # One trade by the pool log it came from, for the site's own check of it
    # (`Autolaunch.Points.Trade`).
    read :by_pool_log do
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
        :transaction_hash,
        :block_hash,
        :block_number,
        :log_index,
        :occurred_at,
        :side,
        :currency_amount,
        :currency_symbol,
        :token_amount,
        :trader
      ]

      upsert? true
      upsert_identity :pool_log

      # The trader is written only with the row: a later write keeps it.
      upsert_fields [
        :block_hash,
        :block_number,
        :occurred_at,
        :side,
        :currency_amount,
        :currency_symbol,
        :token_amount
      ]

      emit Autolaunch.Signals, :trade_recorded,
        dynamic?: true,
        description: "Only when this write saved the trade."

      # Writing a trade already saved updates its row, which Ash marks with an
      # `upsert_action` of `:update`.
      change after_action(fn changeset, trade, _context ->
               if Ash.Resource.get_metadata(trade, :upsert_action) == :insert do
                 with :ok <-
                        Ash.Signals.emit(
                          changeset,
                          Autolaunch.Signals,
                          :trade_recorded,
                          Map.take(trade, [:token_id, :transaction_hash, :log_index])
                        ),
                      do: {:ok, trade}
               else
                 {:ok, trade}
               end
             end)
    end
  end

  policies do
    policy action([:recent, :for_token]) do
      authorize_if always()
    end

    policy action([:record, :by_pool_log]) do
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
    # The lowercase wallet that sent the swap's transaction.
    attribute :trader, :string, constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]
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
