defmodule Autolaunch.Accounts.XConnection.Changes.AssignOwner do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Actors.Human

  @impl true
  def change(changeset, _opts, %{actor: %Human{human_account_id: id}}) when is_integer(id) do
    Ash.Changeset.force_change_attribute(changeset, :human_account_id, id)
  end

  def change(changeset, _opts, _context),
    do: Ash.Changeset.add_error(changeset, message: "verified account required")
end

defmodule Autolaunch.Accounts.XConnection do
  @moduledoc """
  A verified, role-scoped X identity owned by one Human account.

  OAuth credentials never live here. A row keeps only the short-lived PKCE
  attempt needed to finish one browser popup and the public identity returned
  by X after that attempt succeeds.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  require Ash.Query

  postgres do
    table "x_connections"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :delete
    end
  end

  actions do
    read :related_public do
      primary? true

      prepare build(
                select: [
                  :id,
                  :role,
                  :x_user_id,
                  :username,
                  :display_name,
                  :avatar_url,
                  :verified_at,
                  :human_account_id
                ]
              )
    end

    create :begin_attempt do
      accept [
        :role,
        :attempt_state,
        :attempt_verifier,
        :attempt_generation,
        :attempt_expires_at,
        :intent_sequence,
        :intent_generation
      ]

      change Autolaunch.Accounts.XConnection.Changes.AssignOwner
    end

    create :record_intent do
      accept [:role, :intent_sequence, :intent_generation]
      change Autolaunch.Accounts.XConnection.Changes.AssignOwner
    end

    read :mine do
      filter expr(human_account_id == ^actor(:human_account_id))
      prepare build(sort: [role: :asc])
    end

    read :mine_by_role do
      get? true
      argument :role, :atom, allow_nil?: false, constraints: [one_of: [:profile, :company]]
      filter expr(human_account_id == ^actor(:human_account_id) and role == ^arg(:role))
    end

    read :mine_by_role_for_update do
      get? true
      argument :role, :atom, allow_nil?: false, constraints: [one_of: [:profile, :company]]
      filter expr(human_account_id == ^actor(:human_account_id) and role == ^arg(:role))
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    read :public_for_humans do
      argument :human_account_ids, {:array, :integer}, allow_nil?: false
      filter expr(human_account_id in ^arg(:human_account_ids) and not is_nil(verified_at))

      prepare build(
                sort: [human_account_id: :asc, role: :asc],
                select: [
                  :id,
                  :role,
                  :x_user_id,
                  :username,
                  :display_name,
                  :avatar_url,
                  :verified_at,
                  :human_account_id
                ]
              )
    end

    update :replace_attempt do
      accept [
        :attempt_state,
        :attempt_verifier,
        :attempt_generation,
        :attempt_expires_at,
        :intent_sequence,
        :intent_generation
      ]

      require_atomic? false
    end

    update :complete_attempt do
      accept [:x_user_id, :username, :display_name, :avatar_url, :verified_at]
      argument :next_generation, :uuid, allow_nil?: false
      require_atomic? false
      change set_attribute(:attempt_state, nil)
      change set_attribute(:attempt_verifier, nil)
      change set_attribute(:attempt_generation, arg(:next_generation))
      change set_attribute(:attempt_expires_at, nil)
    end

    update :clear_attempt do
      accept []
      require_atomic? false
      change set_attribute(:attempt_state, nil)
      change set_attribute(:attempt_verifier, nil)
      change set_attribute(:attempt_generation, nil)
      change set_attribute(:attempt_expires_at, nil)
    end

    update :cancel_attempt do
      accept []
      argument :intent_sequence, :integer, allow_nil?: false
      argument :intent_generation, :uuid, allow_nil?: false
      require_atomic? false
      change set_attribute(:attempt_state, nil)
      change set_attribute(:attempt_verifier, nil)
      change set_attribute(:attempt_generation, nil)
      change set_attribute(:attempt_expires_at, nil)
      change set_attribute(:intent_sequence, arg(:intent_sequence))
      change set_attribute(:intent_generation, arg(:intent_generation))
    end

    update :disconnect do
      accept []
      argument :intent_sequence, :integer, allow_nil?: false
      argument :intent_generation, :uuid, allow_nil?: false
      require_atomic? false
      change set_attribute(:x_user_id, nil)
      change set_attribute(:username, nil)
      change set_attribute(:display_name, nil)
      change set_attribute(:avatar_url, nil)
      change set_attribute(:verified_at, nil)
      change set_attribute(:attempt_state, nil)
      change set_attribute(:attempt_verifier, nil)
      change set_attribute(:attempt_generation, nil)
      change set_attribute(:attempt_expires_at, nil)
      change set_attribute(:intent_sequence, arg(:intent_sequence))
      change set_attribute(:intent_generation, arg(:intent_generation))
    end
  end

  policies do
    policy action(:related_public) do
      authorize_if expr(not is_nil(verified_at))
    end

    policy action(:public_for_humans) do
      authorize_if always()
    end

    policy action([
             :begin_attempt,
             :record_intent,
             :mine,
             :mine_by_role,
             :mine_by_role_for_update
           ]) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
    end

    policy action([:mine, :mine_by_role, :mine_by_role_for_update]) do
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end

    policy action([
             :replace_attempt,
             :complete_attempt,
             :clear_attempt,
             :cancel_attempt,
             :disconnect
           ]) do
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:profile, :company]
    end

    attribute :x_user_id, :string do
      public? true
      constraints max_length: 64, trim?: true
    end

    attribute :username, :string do
      public? true
      constraints max_length: 64, trim?: true
    end

    attribute :display_name, :string do
      public? true
      constraints max_length: 100, trim?: true
    end

    attribute :avatar_url, :string do
      public? true
      constraints max_length: 500, trim?: true
    end

    attribute :verified_at, :utc_datetime_usec do
      public? true
    end

    attribute :attempt_state, :string do
      sensitive? true
      constraints max_length: 512
    end

    attribute :attempt_verifier, :string do
      sensitive? true
      constraints max_length: 512
    end

    attribute :attempt_generation, :uuid do
      sensitive? true
    end

    attribute :attempt_expires_at, :utc_datetime_usec do
      sensitive? true
    end

    attribute :intent_sequence, :integer do
      sensitive? true
    end

    attribute :intent_generation, :uuid do
      sensitive? true
    end

    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end
  end

  identities do
    identity :one_role_per_human, [:human_account_id, :role]
  end
end
