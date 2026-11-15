defmodule Autolaunch.TokenStake do
  @moduledoc """
  Stakes of a launched token in its launch's splitter, one row per `Staked`
  log, written by `Autolaunch.TokenTrades` in the same pass and under the same
  cursor as the token's trades. The staker is the wallet the log names, the
  one that called `stake`; the amount is in the token's raw units.

  A row is written once and never changed or removed: reading the same log
  again, or rebuilding the token's trades after the chain changed, keeps the
  row as first saved, and a stake the chain later took back stays saved.
  Unstaking is not recorded, and a `Staked` log of nothing is not saved.

  A stake offers Regent Points its award only when it is first saved, so one
  saved while its rule is not approved is never offered later.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @address ~r/\A0x[0-9a-f]{40}\z/
  @hash ~r/\A0x[0-9a-f]{64}\z/

  postgres do
    table "token_stakes"
    repo Autolaunch.Repo
  end

  actions do
    # One stake, for the site's own check of it (`Autolaunch.Points.Stake`).
    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :record do
      accept [
        :token_id,
        :chain_id,
        :splitter,
        :staker,
        :amount,
        :transaction_hash,
        :log_index,
        :block_number,
        :block_hash,
        :occurred_at
      ]

      upsert? true
      upsert_identity :chain_log
      upsert_fields []
      upsert_condition expr(false)

      emit Autolaunch.Signals, :stake_recorded,
        dynamic?: true,
        description: "Only when this write saved the stake."

      # Writing a stake already saved changes nothing and returns no row.
      change after_action(fn changeset, stake, _context ->
               if Ash.Resource.get_metadata(stake, :upsert_action) == :insert do
                 with :ok <-
                        Ash.Signals.emit(changeset, Autolaunch.Signals, :stake_recorded, %{
                          stake_id: stake.id
                        }),
                      do: {:ok, stake}
               else
                 {:ok, stake}
               end
             end)
    end
  end

  policies do
    policy action([:record, :by_id]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1]
    # The launch's splitter, where the token is staked.
    attribute :splitter, :string, allow_nil?: false, constraints: [match: @address]
    attribute :staker, :string, allow_nil?: false, constraints: [match: @address]
    # Raw token units, exactly as the log carried them.
    attribute :amount, :decimal, allow_nil?: false, constraints: [greater_than: 0]
    attribute :transaction_hash, :string, allow_nil?: false, constraints: [match: @hash]
    attribute :log_index, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :block_number, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :block_hash, :string, allow_nil?: false, constraints: [match: @hash]
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    # Read through the listing rule, so a Robinhood launch's token is found too.
    belongs_to :token, Autolaunch.Token do
      allow_nil? false
      read_action :listed
    end
  end

  identities do
    identity :chain_log, [:chain_id, :transaction_hash, :log_index]
  end
end
