defmodule Autolaunch.Indexer.Source do
  @moduledoc """
  One contract address this indexer is allowed to read Base logs for.

  Every launch discovers a new auction address, so the watched set is stored
  evidence rather than configuration, and `eth_getLogs` is never issued without
  an admitted address and the block it becomes interesting at.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "indexer_sources"
    repo Autolaunch.Repo

    check_constraints do
      check_constraint :start_block, "indexer_sources_start_block_nonnegative",
        check: "start_block >= 0",
        message: "start block must be nonnegative"
    end
  end

  actions do
    read :for_chain do
      argument :chain_id, :integer, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id))
      prepare build(sort: [start_block: :asc, address: :asc])
    end

    read :for_address do
      get? true
      argument :chain_id, :integer, allow_nil?: false
      argument :address, :string, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id) and address == ^arg(:address))
    end

    create :admit do
      accept [:chain_id, :address, :start_block]
    end
  end

  policies do
    policy always() do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :address, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]

    attribute :start_block, :integer, allow_nil?: false, constraints: [min: 0]
    timestamps()
  end

  identities do
    identity :unique_source, [:chain_id, :address]
  end
end
