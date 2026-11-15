defmodule Autolaunch.CoveredCalls.Cursor do
  @moduledoc """
  How far `Autolaunch.CoveredCalls.Sales` has read one market's covered-calls
  contract, at the latest block: the first block not read yet, and the head
  and when it was last seen. A reading that disagrees with the saved sales sets
  `rescan_from`, the earliest block where it did, and the reader reads nothing
  more on that contract until an operator clears it
  (`bin/clear-covered-call-sales-stop`), which reads again from there.
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

    # The contracts an operator asks to read again, while they are stopped.
    read :stopped do
      argument :contract, :string, allow_nil?: false, constraints: [match: @address]
      filter expr(contract == ^arg(:contract) and not is_nil(rescan_from))
    end

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

    # Keeps the earliest block where the chain disagreed.
    update :stop do
      accept []
      require_atomic? true
      argument :block, :integer, allow_nil?: false, constraints: [min: 0]

      change atomic_update(
               :rescan_from,
               expr(
                 if is_nil(rescan_from) or rescan_from > ^arg(:block),
                   do: ^arg(:block),
                   else: rescan_from
               )
             )
    end

    # After the record was put right by hand: the next pass reads from the
    # block where the chain disagreed, and the cursor counts as fresh again
    # only once that pass has read the head.
    update :clear do
      accept []
      require_atomic? false

      change fn changeset, _context ->
        %{next_block: next, rescan_from: from} = changeset.data

        Ash.Changeset.force_change_attributes(changeset, %{
          next_block: min(next, from),
          rescan_from: nil,
          observed_at: nil
        })
      end
    end
  end

  policies do
    policy action([:read, :stopped, :open, :advance, :stop, :clear]) do
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
    attribute :rescan_from, :integer, constraints: [min: 0]
  end

  identities do
    identity :contract, [:chain_id, :contract]
  end
end
