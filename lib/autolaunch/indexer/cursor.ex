defmodule Autolaunch.Indexer.Cursor do
  @moduledoc """
  The Base ingest position, and the lease that admits one writer to it.

  `next_block_to_fetch` is the block this indexer will read next, never the last
  one it processed, so bootstrap, late-source backfill and reorg rewind all name
  the same fact and a planned range is exact rather than relative.

  The lease lives on this row so acquisition, every commit and source admission
  contend for one `FOR UPDATE` lock. Expiry is measured against PostgreSQL's own
  clock; no application clock decides who owns the chain.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "indexer_cursors"
    repo Autolaunch.Repo

    check_constraints do
      check_constraint :next_block_to_fetch, "indexer_cursors_next_block_nonnegative",
        check: "next_block_to_fetch >= 0",
        message: "next block to fetch must be nonnegative"
    end
  end

  actions do
    # The primary read is what a locked row's update re-reads through.
    defaults [:read]

    read :for_chain do
      get? true
      argument :chain_id, :integer, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id))
    end

    update :claim_lease do
      accept [:lease_owner, :lease_expires_at]
    end

    update :release_lease do
      accept []
      change set_attribute(:lease_owner, nil)
      change set_attribute(:lease_expires_at, nil)
    end

    update :move_to do
      accept [:next_block_to_fetch]
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
    attribute :next_block_to_fetch, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :lease_owner, :string, constraints: [max_length: 64]
    attribute :lease_expires_at, :utc_datetime_usec
    timestamps()
  end

  identities do
    identity :unique_chain, [:chain_id]
  end
end
