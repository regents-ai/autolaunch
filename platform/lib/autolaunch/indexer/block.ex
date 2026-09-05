defmodule Autolaunch.Indexer.Block do
  @moduledoc """
  One Base block header, identified by the hash rather than the height.

  A height is a non-unique fact because a reorg puts two different blocks at
  one number; `(chain_id, block_hash)` is the only identity, and canonical,
  noncanonical and finalized stay three distinct stored facts about it.

  Nothing here is ever rewritten by a replay: an orphan keeps its evidence and a
  finalized header keeps its promotion, so re-reading the same range can only
  confirm what is stored.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "indexer_blocks"
    repo Autolaunch.Repo

    check_constraints do
      check_constraint :block_number, "indexer_blocks_block_number_nonnegative",
        check: "block_number >= 0",
        message: "block number must be nonnegative"

      check_constraint :finalized, "indexer_blocks_finalized_is_canonical",
        check: "canonical or not finalized",
        message: "a finalized block must be canonical"
    end

    # One canonical block per height is a database fact, not a convention the
    # writer is trusted to keep; the index also serves every bounded canonical
    # height window, because that window can hold no more rows than heights.
    #
    # The finalized frontier is the one read whose work would otherwise grow
    # with the retained ledger, so it gets its own ordinary index. Promotion and
    # retirement rewrite `finalized` and `canonical`, so neither may be a
    # partial-index predicate here: an entry must move between index positions,
    # never in and out of the index the frontier read depends on.
    custom_indexes do
      index [:chain_id, :block_number],
        unique: true,
        where: "canonical",
        name: "indexer_blocks_canonical_height_index"

      index [:chain_id, :finalized, :block_number],
        name: "indexer_blocks_finalized_frontier_index"
    end
  end

  actions do
    # The primary read is what a marked row's update re-reads through.
    defaults [:read]

    read :canonical_between do
      argument :chain_id, :integer, allow_nil?: false
      argument :from_block_number, :integer, allow_nil?: false
      argument :to_block_number, :integer, allow_nil?: false

      filter expr(
               chain_id == ^arg(:chain_id) and block_number >= ^arg(:from_block_number) and
                 block_number <= ^arg(:to_block_number) and canonical == true
             )
    end

    # The two ends of the finalized segment. Promotion grows it upward from the
    # head and downward from the base, so these are the only two rows a steady
    # pass has to find, and one index serves both.
    read :finalized_head do
      argument :chain_id, :integer, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id) and finalized == true)
      prepare build(sort: [block_number: :desc], limit: 1)
    end

    read :finalized_base do
      argument :chain_id, :integer, allow_nil?: false
      filter expr(chain_id == ^arg(:chain_id) and finalized == true)
      prepare build(sort: [block_number: :asc], limit: 1)
    end

    read :by_hashes do
      argument :chain_id, :integer, allow_nil?: false
      argument :block_hashes, {:array, :string}, allow_nil?: false

      filter expr(chain_id == ^arg(:chain_id) and block_hash in ^arg(:block_hashes))
    end

    update :mark_finalized do
      accept []
      change set_attribute(:finalized, true)
    end

    update :mark_noncanonical do
      accept []
      change set_attribute(:canonical, false)
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
    attribute :block_number, :integer, allow_nil?: false, constraints: [min: 0]

    attribute :block_hash, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/]

    attribute :parent_hash, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/]

    attribute :canonical, :boolean, allow_nil?: false, default: true
    attribute :finalized, :boolean, allow_nil?: false, default: false
    timestamps()
  end

  identities do
    identity :unique_block, [:chain_id, :block_hash]
  end
end
