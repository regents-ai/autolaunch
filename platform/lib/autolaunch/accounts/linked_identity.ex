defmodule Autolaunch.Accounts.LinkedIdentity do
  use Ash.Resource,
    otp_app: :autolaunch,
    primary_read_warning?: false,
    domain: Autolaunch.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "linked_identities"
    repo Autolaunch.Repo
  end

  field_policies do
    field_policy [:subject, :metadata] do
      authorize_if Autolaunch.Checks.SystemActor
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    action :connect_ens, :map do
      argument :name, :string, allow_nil?: false, constraints: [max_length: 253]
      run fn input, context -> Autolaunch.Accounts.ConnectEns.run(input, context) end
    end

    read :public_for_humans do
      argument :human_account_ids, {:array, :integer}, allow_nil?: false

      filter expr(
               human_account_id in ^arg(:human_account_ids) and provider in [:x, :github, :ens] and
                 not is_nil(username)
             )

      prepare build(
                select: [
                  :id,
                  :provider,
                  :username,
                  :display_name,
                  :verified_at,
                  :human_account_id
                ]
              )
    end

    read :related_public do
      primary? true
      filter expr(provider in [:x, :github, :ens] and not is_nil(username))

      prepare build(
                select: [
                  :id,
                  :provider,
                  :username,
                  :display_name,
                  :verified_at,
                  :human_account_id
                ]
              )
    end

    create :upsert_verified do
      accept []

      argument :provider, :atom,
        allow_nil?: false,
        constraints: [one_of: [:x, :github, :farcaster, :ens, :world]]

      argument :subject, :string, allow_nil?: false
      argument :username, :string
      argument :display_name, :string
      argument :verified_at, :utc_datetime_usec, allow_nil?: false
      argument :metadata, :map, allow_nil?: false
      argument :human_account_id, :integer, allow_nil?: false

      change set_attribute(:provider, arg(:provider))
      change set_attribute(:subject, arg(:subject))
      change set_attribute(:username, arg(:username))
      change set_attribute(:display_name, arg(:display_name))
      change set_attribute(:verified_at, arg(:verified_at))
      change set_attribute(:metadata, arg(:metadata))
      change set_attribute(:human_account_id, arg(:human_account_id))

      upsert? true
      upsert_identity :unique_provider_per_account
      upsert_fields [:subject, :username, :display_name, :verified_at, :metadata]
    end

    read :read_mine do
      filter expr(human_account_id == ^actor(:human_account_id))
      prepare build(sort: [provider: :asc])
    end

    read :for_account do
      argument :human_account_id, :integer, allow_nil?: false
      filter expr(human_account_id == ^arg(:human_account_id))
      prepare build(sort: [provider: :asc])
    end

    read :by_provider_subject do
      get? true
      argument :provider, :atom, allow_nil?: false
      argument :subject, :string, allow_nil?: false
      filter expr(provider == ^arg(:provider) and subject == ^arg(:subject))
    end

    destroy :remove_verified do
      accept []
      require_atomic? false
    end
  end

  policies do
    policy action([:public_for_humans, :related_public]) do
      authorize_if always()
    end

    policy action([:upsert_verified, :for_account, :by_provider_subject, :remove_verified]) do
      authorize_if Autolaunch.Checks.SystemActor
    end

    policy action([:read_mine, :connect_ens]) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:x, :github, :farcaster, :ens, :world]
    end

    attribute :subject, :string, allow_nil?: false, public?: true, sensitive?: true
    attribute :username, :string, public?: true
    attribute :display_name, :string, public?: true
    attribute :verified_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true, sensitive?: true
    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end
  end

  identities do
    identity :unique_provider_per_account, [:provider, :human_account_id]
    identity :unique_subject_per_provider, [:provider, :subject]
  end
end
