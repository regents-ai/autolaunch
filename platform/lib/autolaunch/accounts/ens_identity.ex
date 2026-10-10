defmodule Autolaunch.Accounts.EnsIdentity do
  @moduledoc """
  The ENS name and picture Ethereum mainnet publishes for an account's wallet.

  This is a copy of public chain state, not identity evidence: the account's
  own row keeps the verified Privy identity and wallet. Each sign-in asks again
  (`:request_lookup`), and one job, queued in the same transaction, reads the
  chain outside any transaction (`LookUp`). A wallet with no verified name is
  stored with none; a lookup that keeps failing leaves the last name standing.

  `wallet_address` is the wallet the row was read for, so an account whose
  wallet has since changed is never shown the old wallet's name.

  Lookups run only while the server has an Ethereum endpoint
  (`ETHEREUM_READ_RPC_URL`) and runs background jobs, which a read-only
  prelaunch server does not.
  """

  use Ash.Resource,
    domain: Autolaunch.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshOban]

  alias Autolaunch.Accounts.EnsIdentity.LookUp

  postgres do
    table "account_ens_identities"
    repo Autolaunch.Repo
  end

  oban do
    triggers do
      # Every sign-in queues its own job, so there is no sweep to find missed ones.
      trigger :look_up do
        action :look_up
        where expr(lookup_state == :pending)
        queue :outside_calls
        max_attempts 3
        on_error :lookup_failed
        lock_for_update? false
        scheduler_cron false
        worker_module_name Autolaunch.Accounts.EnsIdentity.Workers.LookUp
      end
    end
  end

  actions do
    defaults [:read]

    create :request_lookup do
      accept [:human_account_id, :wallet_address]
      change set_attribute(:lookup_state, :pending)
      change run_oban_trigger(:look_up)
      upsert? true
      upsert_identity :unique_human_account
      upsert_fields [:wallet_address, :lookup_state, :updated_at]
    end

    update :look_up do
      transaction? false
      require_atomic? false
      change LookUp
    end

    update :lookup_failed do
      change set_attribute(:lookup_state, :failed)
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action(:request_lookup) do
      authorize_if Autolaunch.Checks.SystemActor
    end

    # Chain state anyone can read for themselves, so the account it belongs to
    # is what protects it, not this row.
    policy action(:read) do
      authorize_if always()
    end
  end

  # A finished lookup reaches the open pages of the account it belongs to.
  pub_sub do
    module Phoenix.PubSub
    name Autolaunch.PubSub
    prefix "ens_identity"
    broadcast_type :broadcast
    transform & &1.data

    publish :look_up, [:human_account_id]
  end

  attributes do
    uuid_primary_key :id
    attribute :wallet_address, :string, allow_nil?: false
    attribute :ens_name, :string, public?: true
    attribute :ens_avatar_url, :string, public?: true

    attribute :lookup_state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:pending, :done, :failed]]

    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end
  end

  identities do
    identity :unique_human_account, [:human_account_id]
  end

  @doc "The topic a finished lookup for `human_account_id` is published on."
  def topic(human_account_id), do: "ens_identity:#{human_account_id}"

  @doc "Whether sign-ins look up ENS: the server reads Ethereum mainnet and runs jobs."
  def looking_up?, do: not is_nil(rpc_url()) and not is_nil(Oban.whereis(Oban))

  @doc "The Ethereum mainnet endpoint ENS reads use."
  def rpc_url, do: Application.get_env(:autolaunch, :ethereum_read_rpc_url)
end
