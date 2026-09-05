defmodule Autolaunch.Indexer.Log do
  @moduledoc """
  One raw Base log, stored exactly as the chain emitted it and never decoded.

  `(chain_id, block_hash, log_index)` is the identity, so a transaction that a
  reorg re-includes lands as a new row under its new block hash while the former
  placement survives as evidence. Nothing here carries a canonical flag: a log
  is canonical exactly when the block it belongs to is, and that association is
  immutable.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "indexer_logs"
    repo Autolaunch.Repo

    check_constraints do
      check_constraint :log_index, "indexer_logs_log_index_nonnegative",
        check: "log_index >= 0",
        message: "log index must be nonnegative"

      check_constraint :transaction_index, "indexer_logs_transaction_index_nonnegative",
        check: "transaction_index >= 0",
        message: "transaction index must be nonnegative"
    end

    references do
      reference :block, on_delete: :restrict
    end
  end

  actions do
    read :by_block_hashes do
      argument :chain_id, :integer, allow_nil?: false
      argument :block_hashes, {:array, :string}, allow_nil?: false

      filter expr(chain_id == ^arg(:chain_id) and block_hash in ^arg(:block_hashes))
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

    attribute :block_hash, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/]

    attribute :log_index, :integer, allow_nil?: false, constraints: [min: 0]

    attribute :transaction_hash, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{64}\z/]

    attribute :transaction_index, :integer, allow_nil?: false, constraints: [min: 0]

    attribute :address, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A0x[0-9a-f]{40}\z/]

    attribute :topics, {:array, :string},
      allow_nil?: false,
      constraints: [max_length: 4, items: [match: ~r/\A0x[0-9a-f]{64}\z/]]

    attribute :data, :string, allow_nil?: false, constraints: [match: ~r/\A0x([0-9a-f]{2})*\z/]
    timestamps()
  end

  relationships do
    belongs_to :block, Autolaunch.Indexer.Block do
      allow_nil? false
    end
  end

  identities do
    identity :unique_log, [:chain_id, :block_hash, :log_index]
  end
end
