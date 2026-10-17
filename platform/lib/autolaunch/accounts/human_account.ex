defmodule Autolaunch.Accounts.HumanAccount do
  @moduledoc """
  A person's shared Regent account, read from the table Regents owns. Every
  Regent site signing in with this Privy app reads and writes the same row, so
  a person has one account everywhere and this site keeps no copy of its own.
  """

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
    # Loading the name and picture after sign-in writes the account reads it
    # again through the primary read.
    read :read do
      primary? true
    end

    read :points_account do
      get? true
      argument :id, :integer, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    read :by_privy_did do
      get? true
      argument :privy_did, :string, allow_nil?: false
      filter expr(privy_user_id == ^arg(:privy_did))
      prepare build(load: [:display_name, :ens_name, :ens_avatar_url])
    end

    # The accounts whose signed-in wallet is one of these addresses (lowercase).
    # A Robinhood launch's launcher had to be its creator's signed-in wallet, so
    # this names who launched it.
    read :by_signed_in_wallets do
      argument :wallet_addresses, {:array, :string}, allow_nil?: false
      filter expr(string_downcase(wallet_address) in ^arg(:wallet_addresses))
    end

    read :read_self do
      get? true
      argument :id, :integer, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare build(load: [:display_name, :ens_name, :ens_avatar_url])
    end

    create :register_verified do
      accept [:privy_user_id, :wallet_address, :wallet_addresses]
      upsert? true
      upsert_identity :unique_privy_user_id
      upsert_fields []
      change load([:display_name])
    end

    # A sign-in with no linked wallet withdraws the evidence: no primary and an
    # empty list.
    update :refresh_verified do
      accept [:wallet_address, :wallet_addresses]
      require_atomic? false
      validate present(:wallet_addresses)
      change load([:display_name, :ens_name, :ens_avatar_url])
    end
  end

  policies do
    policy action([
             :read,
             :points_account,
             :by_privy_did,
             :by_signed_in_wallets,
             :register_verified,
             :refresh_verified
           ]) do
      authorize_if Autolaunch.Checks.SystemActor
    end

    policy action(:read_self) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
    end

    policy action(:read_self) do
      authorize_if expr(id == ^actor(:human_account_id))
    end
  end

  attributes do
    integer_primary_key :id
    attribute :privy_user_id, :string, allow_nil?: false, sensitive?: true
    attribute :wallet_address, :string, sensitive?: true
    attribute :wallet_addresses, {:array, :string}, default: [], sensitive?: true
    attribute :avatar, :map
    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_one :ens_identity, Autolaunch.Accounts.EnsIdentity do
      destination_attribute :human_account_id
    end
  end

  calculations do
    # The name set in the person's shared Regent profile.
    calculate :display_name, :string, Autolaunch.Accounts.HumanAccount.ProfileName, public?: true

    # The ENS name and picture, only while they were read for the account's
    # current wallet.
    calculate :ens_name,
              :string,
              expr(
                if ens_identity.wallet_address == wallet_address do
                  ens_identity.ens_name
                end
              )

    calculate :ens_avatar_url,
              :string,
              expr(
                if ens_identity.wallet_address == wallet_address do
                  ens_identity.ens_avatar_url
                end
              )
  end

  identities do
    identity :unique_privy_user_id, [:privy_user_id]
  end
end
