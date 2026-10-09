defmodule Autolaunch.Accounts.CanonicalAccount do
  @moduledoc "The shared account, matched by verified Privy ID; local product IDs never change."
  use Ash.Resource,
    domain: Autolaunch.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "platform_human_users"
    schema "regent_names"
    repo Autolaunch.Repo
    migrate? false
  end

  actions do
    read :by_privy_id do
      get? true
      argument :privy_user_id, :string, allow_nil?: false
      filter expr(privy_user_id == ^arg(:privy_user_id))
    end

    read :by_id do
      get? true
      argument :id, :integer, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :register_verified do
      accept [:privy_user_id, :wallet_address, :wallet_addresses]
      upsert? true
      upsert_identity :unique_privy_user_id
      upsert_fields []
    end

    update :refresh_verified do
      accept [:wallet_address, :wallet_addresses]
      require_atomic? false
      validate present(:wallet_addresses)
    end
  end

  policies do
    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    integer_primary_key :id
    attribute :privy_user_id, :string, allow_nil?: false, sensitive?: true
    attribute :wallet_address, :string, sensitive?: true
    attribute :wallet_addresses, {:array, :string}, default: [], sensitive?: true
    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_privy_user_id, [:privy_user_id]
  end
end
