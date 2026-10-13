defmodule Autolaunch.Stocks.AdmissionScan do
  @moduledoc """
  How far the site has read one stock launchpad's `StockAdmitted` logs: the
  next block `Autolaunch.Stocks.Stock.SyncAdmissions` reads from, and the
  stocks those logs named that it could not read or save yet, which it asks
  the chain about again on every run. One row per chain, launchpad and
  deployment run, so a local chain deployed again, which puts the same
  launchpad address on a new history, is read from its own first block.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "stock_admission_scans"
    repo Autolaunch.Repo
  end

  actions do
    defaults [:read]

    read :of_launchpad do
      get? true
      argument :chain_id, :integer, allow_nil?: false
      argument :launchpad, :string, allow_nil?: false
      argument :run_id, :string, allow_nil?: false

      filter expr(
               chain_id == ^arg(:chain_id) and launchpad == ^arg(:launchpad) and
                 run_id == ^arg(:run_id)
             )
    end

    create :advance do
      accept [:chain_id, :launchpad, :run_id, :next_block, :unread]
      upsert? true
      upsert_identity :one_per_launchpad
      upsert_fields [:next_block, :unread]
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

    attribute :launchpad, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]

    attribute :run_id, :string, allow_nil?: false, constraints: [max_length: 200]
    attribute :next_block, :integer, allow_nil?: false, constraints: [min: 0]

    attribute :unread, {:array, :string},
      allow_nil?: false,
      default: [],
      constraints: [items: [match: ~r/\A0x[0-9a-f]{40}\z/]]

    timestamps()
  end

  identities do
    identity :one_per_launchpad, [:chain_id, :launchpad, :run_id]
  end
end
