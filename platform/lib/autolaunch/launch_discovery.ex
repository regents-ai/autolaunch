defmodule Autolaunch.LaunchDiscovery do
  @moduledoc """
  One launch the chain shows on a Base launchpad, and whether it is a launch
  this site's accounts reviewed.

  A launch is listed from chain evidence alone. The creator's browser may never
  report its hash, and nothing here waits for it:

  - the Base ledger records every Revstake factory `LaunchCreated` it stores;
  - every minute `:discover_memestake` records each new Memestake launchpad
    launch and the transaction that created it.

  Every minute the `:resolve` trigger takes each launch still `pending` and
  looks for the reviewed launch it carried out: a review whose signer is the
  launch's signer, whose exact target and calldata that transaction sent. A
  match lists the launch for that review's account, through the same verified
  press a browser report would have recorded. A launch no review of
  this site carried out is `unlisted`. A launch the chain cannot answer for yet
  stays `pending`, with the reason, until it can.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    extensions: [AshOban],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  oban do
    triggers do
      trigger :resolve do
        action :resolve
        read_action :read
        worker_read_action :read
        queue :launch_listing
        scheduler_cron "* * * * *"
        max_attempts 1
        where expr(state == :pending)
        worker_module_name Autolaunch.LaunchDiscovery.Workers.Resolve
        scheduler_module_name Autolaunch.LaunchDiscovery.Schedulers.Resolve
      end
    end

    scheduled_actions do
      schedule :discover_memestake, "* * * * *" do
        action :discover_memestake
        queue :launch_listing
        worker_module_name Autolaunch.LaunchDiscovery.Workers.DiscoverMemestake
      end
    end
  end

  postgres do
    table "launch_discoveries"
    repo Autolaunch.Repo

    identity_index_names one_per_launch: "launch_discoveries_launch_index"
  end

  actions do
    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    read :latest do
      get? true
      argument :chain_id, :integer, allow_nil?: false
      argument :contract, :string, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id) and contract == ^arg(:contract))
      prepare build(sort: [launch_id: :desc], limit: 1)
    end

    # A replayed log or record finds the launch already recorded and changes
    # nothing about it, however far its resolution has got.
    create :record do
      accept [
        :launchpad,
        :chain_id,
        :contract,
        :launch_id,
        :launcher,
        :auction,
        :transaction_hash
      ]

      upsert? true
      upsert_identity :one_per_launch
      upsert_fields []
    end

    action :discover_memestake do
      run fn input, context ->
        Autolaunch.LaunchDiscovery.DiscoverMemestake.run(input, context)
      end
    end

    # Reads the chain, then records the match in its own transaction, so no
    # database transaction is held open around the reads.
    update :resolve do
      require_atomic? false
      transaction? false
      change Autolaunch.LaunchDiscovery.Resolve
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :launchpad, :atom,
      allow_nil?: false,
      constraints: [one_of: [:base_revstake, :base_memestake]]

    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1]

    # The contract that numbers the launches: the Revstake factory, or the
    # Memestake launchpad.
    attribute :contract, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :launch_id, :integer, allow_nil?: false, constraints: [min: 1]

    # The wallet that sent the launch, as the launchpad recorded it.
    attribute :launcher, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :auction, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :transaction_hash, :string,
      allow_nil?: false,
      constraints: [min_length: 66, max_length: 66]

    attribute :state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :listed, :unlisted]]

    # Set once, from the matched review: the account it was prepared for.
    attribute :creator_human_account_id, :integer

    # Why a launch is still pending or was left unlisted.
    attribute :reason, :string, constraints: [max_length: 120]

    timestamps()
  end

  identities do
    identity :one_per_launch, [:chain_id, :contract, :launch_id]
  end
end
