defmodule Autolaunch.Accounts.LinkedIdentity do
  @moduledoc """
  An account Privy verified for one human account (X, GitHub, Farcaster), or
  an ENS name its wallet controls, one per provider. Several human accounts may
  link the same account of a shared provider (`@shared_providers`, X); any
  other provider's account or ENS name is linked to one human account at a time.

  `inserted_at` is when this subject was linked to this account. A sign-in
  with a subject already linked refreshes the link and leaves it
  (`:refresh_verified`); a sign-in with a subject new to the account, its first
  for the provider or one replacing the earlier subject, links it anew and
  resets it (`:upsert_verified`), and only that tells the site
  (`Autolaunch.Accounts.Signals` `:social_linked`). An ENS name is saved again
  with each lookup, which resets its time too; nothing reads an ENS row's time.
  `verified_at` is the newest check of the link.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    primary_read_warning?: false,
    domain: Autolaunch.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # The providers whose accounts several human accounts may link at once, and
  # the one place that choice is made. Every other provider's subject, an ENS
  # name included, is held by one account, which the database keeps to
  # (`:unique_subject_per_provider`).
  @shared_providers [:x]

  postgres do
    table "linked_identities"
    repo Autolaunch.Repo

    identity_wheres_to_sql unique_subject_per_provider:
                             "provider NOT IN (#{Enum.map_join(@shared_providers, ", ", &"'#{&1}'")})"

    custom_indexes do
      # `:first_link` reads the links to one account by its provider and
      # subject, shared or not. Built in the same short transaction as the
      # subject rule.
      index [:provider, :subject]
    end
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
      # A sign-in reaches this only for a subject new to the account, its first
      # for the provider or one replacing the earlier subject, so `inserted_at`
      # restarts with it; an ENS lookup saves its name here each time.
      upsert_fields [:subject, :username, :display_name, :verified_at, :metadata, :inserted_at]

      emit Autolaunch.Accounts.Signals, :social_linked,
        where: [one_of(:provider, [:x, :github, :farcaster])]
    end

    # A sign-in whose subject is still linked to the account. The sign-in finds
    # the row by provider, subject and account in the statement that updates it
    # (`Autolaunch.Accounts.VerifiedSession`).
    update :refresh_verified do
      accept [:username, :display_name, :verified_at, :metadata]
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

    # Of the accounts that hold one social account, the link made first: the one
    # its Points answer for (`Autolaunch.Points.LinkedSocial`), so a later link by
    # another account moves nothing.
    read :first_link do
      get? true
      argument :provider, :atom, allow_nil?: false
      argument :subject, :string, allow_nil?: false
      filter expr(provider == ^arg(:provider) and subject == ^arg(:subject))
      prepare build(sort: [inserted_at: :asc, human_account_id: :asc], limit: 1)
    end

    # Each account's link to one provider made before a moment, such as the
    # Points start run's own time; only whose it is and what it links, in
    # `:first_link`'s order.
    read :linked_before do
      argument :provider, :atom, allow_nil?: false
      argument :at, :utc_datetime_usec, allow_nil?: false
      filter expr(provider == ^arg(:provider) and inserted_at < ^arg(:at))

      prepare build(
                select: [:provider, :subject, :human_account_id],
                sort: [inserted_at: :asc, human_account_id: :asc]
              )
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

    policy action([
             :upsert_verified,
             :refresh_verified,
             :for_account,
             :first_link,
             :linked_before,
             :remove_verified
           ]) do
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
    # One row per account and provider, so one per account and subject, shared
    # or not: sign-ins of one account at once meet in `:upsert_verified`, whose
    # conflict target this is.
    identity :unique_provider_per_account, [:provider, :human_account_id]

    # A sign-in reports the subject error as an account another account holds
    # (`Autolaunch.Accounts.VerifiedSession`), and Connect ENS as a name another
    # account has (`Autolaunch.Accounts.ConnectEns`).
    identity :unique_subject_per_provider, [:provider, :subject] do
      where expr(provider not in ^@shared_providers)
      field_names [:subject]
    end
  end
end
