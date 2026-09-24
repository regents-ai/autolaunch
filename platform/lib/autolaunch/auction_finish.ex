defmodule Autolaunch.AuctionFinish do
  @moduledoc """
  One launch on a launchpad this site describes, and whether its auction has
  been finished.

  An auction does not finish itself. Once its migration block has passed,
  someone has to call `migrate`, which either graduates the launch (pool,
  locked liquidity, vesting) or fails it (bids become refundable). Anyone may
  call it, so the site does, from its finishing wallet.

  Every minute `:discover` records the launches created since its last run, and
  the `:finish` trigger looks at each launch still running: once its migration
  block has passed it sends `migrate`, and once the chain says the launch
  graduated or failed the row is not looked at again. Every `migrate` sent is
  an `AuctionFinish.Transaction`, recorded before it is broadcast, and a launch
  is sent another only once the chain has settled the last.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    extensions: [AshOban],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  oban do
    triggers do
      trigger :finish do
        action :finish
        read_action :read
        worker_read_action :read
        queue :auction_finishing
        scheduler_cron "* * * * *"
        max_attempts 1

        where expr(state == :running)

        worker_module_name Autolaunch.AuctionFinish.Workers.Finish
        scheduler_module_name Autolaunch.AuctionFinish.Schedulers.Finish
      end
    end

    scheduled_actions do
      schedule :discover, "* * * * *" do
        action :discover
        queue :auction_finishing
        worker_module_name Autolaunch.AuctionFinish.Workers.Discover
      end
    end
  end

  postgres do
    table "auction_finishes"
    repo Autolaunch.Repo

    identity_index_names one_per_launch: "auction_finishes_launch_index"
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

    create :record do
      accept [:launchpad, :chain_id, :contract, :launch_id, :auction, :migration_block, :state]
    end

    action :discover do
      run fn input, context -> Autolaunch.AuctionFinish.Discover.run(input, context) end
    end

    # Reads the chain and may send a transaction, so no database transaction
    # is held open around it.
    update :finish do
      require_atomic? false
      transaction? false
      change Autolaunch.AuctionFinish.Finish
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
      constraints: [one_of: [:base_revstake, :base_memestake, :robinhood_memestake]]

    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1]

    # The contract that numbers the launches: the Revstake factory, or the
    # Memestake launchpad.
    attribute :contract, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :launch_id, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :auction, :string,
      allow_nil?: false,
      constraints: [min_length: 42, max_length: 42]

    attribute :migration_block, :integer, allow_nil?: false, constraints: [min: 0]

    attribute :state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:running, :graduated, :failed]]

    timestamps()
  end

  identities do
    identity :one_per_launch, [:chain_id, :contract, :launch_id]
  end
end
