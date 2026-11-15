defmodule Autolaunch.CoveredCalls.Cursor do
  @moduledoc """
  How far `Autolaunch.CoveredCalls.Sales` has read one market's covered-calls
  contract, at the latest block: the first block not read yet, and the head
  and when it was last seen. It moves only from where its pass found it
  (`Autolaunch.CoveredCalls.CursorUnmoved`), in the transaction that saves the
  sales it read.
  """
  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch.CoveredCalls,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @address ~r/\A0x[0-9a-f]{40}\z/
  @hash ~r/\A0x[0-9a-f]{64}\z/

  postgres do
    table "covered_call_cursors"
    repo Autolaunch.Repo
  end

  actions do
    defaults [:read]

    # A cursor already opened, by another pass, is returned as it is.
    create :open do
      accept [:chain_id, :contract, :next_block]
      upsert? true
      upsert_identity :contract
      upsert_fields []
      upsert_condition expr(false)
      return_skipped_upsert? true
    end

    update :advance do
      accept [:next_block, :head_block, :head_block_hash, :observed_at]
      require_attributes [:next_block, :head_block, :head_block_hash, :observed_at]
      argument :from, :integer, allow_nil?: false
      validate Autolaunch.CoveredCalls.CursorUnmoved
    end
  end

  policies do
    policy action([:read, :open, :advance]) do
      authorize_if Autolaunch.Checks.SystemActor
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :chain_id, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :contract, :string, allow_nil?: false, constraints: [match: @address]
    # The first block not read yet.
    attribute :next_block, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :head_block, :integer, constraints: [min: 0]
    attribute :head_block_hash, :string, constraints: [match: @hash]
    # When the head was last read.
    attribute :observed_at, :utc_datetime_usec
  end

  identities do
    identity :contract, [:chain_id, :contract]
  end
end
