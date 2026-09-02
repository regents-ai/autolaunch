defmodule Autolaunch.Accounts.HumanAccount do
  use Ash.Resource,
    domain: Autolaunch.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "human_accounts"
    repo Autolaunch.Repo
  end

  actions do
    read :by_privy_did do
      get? true
      argument :privy_did, :string, allow_nil?: false
      filter expr(privy_user_id == ^arg(:privy_did))
    end

    read :read_self do
      get? true
      argument :id, :integer, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    read :public_comment_author

    read :public_profile_source do
      public? false
      get? true
      argument :id, :integer, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :register_verified do
      accept []
      argument :privy_did, :string, allow_nil?: false
      argument :wallet_address, :string
      argument :wallet_addresses, {:array, :string}
      change set_attribute(:privy_user_id, arg(:privy_did))
      change set_attribute(:wallet_address, arg(:wallet_address))
      change set_attribute(:wallet_addresses, arg(:wallet_addresses))
      upsert? true
      upsert_identity :unique_privy_user_id
      upsert_fields []
    end

    update :refresh_verified do
      accept []
      require_atomic? false
      argument :wallet_address, :string
      argument :wallet_addresses, {:array, :string}
      change Autolaunch.Accounts.Changes.RefreshWalletEvidence
    end

    update :set_display_name do
      accept [:display_name]
    end

    update :set_avatar do
      accept [:avatar]
    end
  end

  policies do
    policy action([:by_privy_did, :register_verified, :refresh_verified, :public_profile_source]) do
      authorize_if Autolaunch.Checks.SystemActor
    end

    policy action(:public_comment_author) do
      authorize_if always()
    end

    policy action([:read_self, :set_display_name, :set_avatar]) do
      authorize_if expr(id == ^actor(:human_account_id))
    end
  end

  attributes do
    integer_primary_key :id
    attribute :privy_user_id, :string, allow_nil?: false, sensitive?: true
    attribute :wallet_address, :string, sensitive?: true
    attribute :wallet_addresses, {:array, :string}, default: [], sensitive?: true
    attribute :world_human_id, :string, sensitive?: true
    attribute :world_verified_at, :utc_datetime
    attribute :display_name, :string, public?: true, constraints: [max_length: 80]
    attribute :avatar, :map
    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_privy_user_id, [:privy_user_id]
    identity :unique_world_human_id, [:world_human_id]
  end
end
