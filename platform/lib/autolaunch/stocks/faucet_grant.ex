defmodule Autolaunch.Stocks.FaucetGrant do
  @moduledoc """
  The last time the test-funds faucet sent one asset to one wallet.

  One row per wallet and asset, replaced on every grant, read and written by
  `Autolaunch.Stocks.Faucet` inside the transaction that sends the grant so
  the cooldown is checked against what was really sent.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "faucet_grants"
    repo Autolaunch.Repo

    identity_index_names one_per_wallet_asset: "faucet_grants_wallet_asset_index"
  end

  actions do
    defaults [:read]

    read :latest do
      get? true
      argument :wallet, :string, allow_nil?: false
      argument :asset, :string, allow_nil?: false
      filter expr(wallet == ^arg(:wallet) and asset == ^arg(:asset))
    end

    create :record do
      accept [:wallet, :asset, :granted_at]
      upsert? true
      upsert_identity :one_per_wallet_asset
      upsert_fields [:granted_at]
    end
  end

  policies do
    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :wallet, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :asset, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 64]
    attribute :granted_at, :utc_datetime_usec, allow_nil?: false
  end

  identities do
    identity :one_per_wallet_asset, [:wallet, :asset]
  end
end
