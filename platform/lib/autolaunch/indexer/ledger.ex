defmodule Autolaunch.Indexer.Ledger do
  @moduledoc """
  Every durable transition the Base ledger makes, and the row lock that orders
  them.

  Source admission and every commit ensure the chain's cursor row and then take
  the same `FOR UPDATE` lock on it, so an admission that rewinds the cursor and
  a range planned from the old position can never interleave: whichever reaches
  the lock second sees the other's decision, and a commit whose lease or exact
  planned cursor no longer holds rolls the whole range back rather than skipping
  or overwriting one.

  Provider work never happens inside these transactions. Headers and logs are
  inserted, never updated: the unique identity decides a duplicate race and a
  replay that disagrees with stored evidence aborts the transaction instead of
  rewriting it.
  """

  require Ash.Query

  alias Autolaunch.Actors.System
  alias Autolaunch.Indexer.{Block, Chain, Cursor, Log, Source}
  alias Autolaunch.LaunchProjection
  alias Autolaunch.Repo

  @actor %System{}

  @typedoc "What a granted lease permits: this owner, this chain, this exact position."
  @type lease :: %{chain_id: pos_integer(), owner: String.t(), next_block: non_neg_integer()}

  @doc """
  Admits one normalized source and pulls the chain cursor back to cover it.

  The first admission creates the cursor at the source's start block; a later
  one behind the cursor rewinds it, so the new address is backfilled while the
  logs already stored replay as no-ops. Any genuinely new address also clears
  the current lease, because a range planned before this address existed would
  otherwise commit past it and skip its logs. Re-stating an address the ledger
  already watches from the same block is the same fact twice: it moves nothing
  and disturbs no live lease. Naming a different start block for it is a
  contradiction and fails closed.
  """
  @spec admit_source(pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def admit_source(chain_id, address, start_block) do
    case Chain.address(address) do
      {:ok, address} -> Repo.transaction(fn -> admit(chain_id, address, start_block) end)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Grants the chain lease to one handler, or reports that a live owner keeps it."
  @spec acquire(pos_integer(), pos_integer()) :: {:ok, lease()} | {:error, atom()}
  def acquire(chain_id, lease_ms) do
    Repo.transaction(fn ->
      case lock(chain_id) do
        nil -> Repo.rollback(:no_source_admitted)
        cursor -> claim(cursor, db_now(), lease_ms)
      end
    end)
  end

  @doc "Releases the lease this owner still holds, so the next cadence starts immediately."
  @spec release(lease()) :: {:ok, term()}
  def release(%{chain_id: chain_id, owner: owner}) do
    Repo.transaction(fn -> chain_id |> lock() |> relinquish(owner) end)
  end

  @doc "Every address admitted for a chain, ascending by the block it starts at."
  @spec sources(pos_integer()) :: [Ash.Resource.record()]
  def sources(chain_id) do
    Source
    |> Ash.Query.for_read(:for_chain, %{chain_id: chain_id}, actor: @actor)
    |> Ash.read!()
  end

  @doc "The canonical block stored at an exact height, or `nil`."
  @spec canonical_block(pos_integer(), non_neg_integer()) :: Ash.Resource.record() | nil
  def canonical_block(chain_id, block_number),
    do: chain_id |> canonical_range(block_number, block_number) |> List.first()

  @doc "Whether this chain already holds that block hash as an abandoned fork."
  @spec abandoned?(pos_integer(), String.t()) :: boolean()
  def abandoned?(chain_id, block_hash),
    do: chain_id |> stored_blocks([block_hash]) |> Enum.any?(&(not &1.canonical))

  @doc """
  Commits one plan under the lease it was made with.

  The lock is retaken, the lease revalidated against database time and the
  cursor revalidated against the exact position the plan was drawn from. Blocks,
  logs, finality promotion and the cursor move land in this single transaction,
  so a rollback advances nothing.
  """
  @spec commit(lease(), tuple(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def commit(lease, plan, bound) do
    Repo.transaction(fn ->
      now = db_now()
      ensure(lease.chain_id, lease.next_block, now)
      cursor = lock(lease.chain_id)

      if held?(cursor, lease, now),
        do: apply_plan(cursor, plan, bound, now),
        else: Repo.rollback(:lease_lost)
    end)
  end

  defp admit(chain_id, address, start_block) do
    ensure(chain_id, start_block, db_now())
    cursor = lock(chain_id)

    case source(chain_id, address) do
      nil -> opened(cursor, chain_id, address, start_block)
      %{start_block: ^start_block} = admitted -> admitted
      _contradicted -> Repo.rollback(:source_start_conflict)
    end
  end

  defp opened(cursor, chain_id, address, start_block) do
    source =
      Ash.create!(
        Source,
        %{chain_id: chain_id, address: address, start_block: start_block},
        action: :admit,
        actor: @actor
      )

    cursor
    |> invalidate()
    |> move_to(min(cursor.next_block_to_fetch, start_block))

    source
  end

  # An in-flight plan was drawn from a source set this address was not in, so it
  # may commit over the heights this address emits from without ever asking for
  # them. Clearing the lease under the same lock refuses that commit outright,
  # whether or not the new start block is low enough to move the cursor; the
  # pass that follows is planned from the whole admitted set.
  defp invalidate(cursor),
    do: Ash.update!(cursor, %{}, action: :release_lease, actor: @actor)

  defp claim(cursor, now, lease_ms) do
    if leased?(cursor, now), do: Repo.rollback(:leased), else: grant(cursor, now, lease_ms)
  end

  defp grant(cursor, now, lease_ms) do
    owner = Ash.UUID.generate()

    cursor
    |> Ash.Changeset.for_update(
      :claim_lease,
      %{lease_owner: owner, lease_expires_at: DateTime.add(now, lease_ms, :millisecond)},
      actor: @actor
    )
    |> Ash.update!()
    |> then(&%{chain_id: &1.chain_id, owner: owner, next_block: &1.next_block_to_fetch})
  end

  defp relinquish(%{lease_owner: owner} = cursor, owner),
    do: Ash.update!(cursor, %{}, action: :release_lease, actor: @actor)

  defp relinquish(cursor, _other_owner), do: cursor

  defp leased?(%{lease_expires_at: nil}, _now), do: false
  defp leased?(%{lease_expires_at: expires_at}, now), do: DateTime.after?(expires_at, now)

  defp held?(%{lease_owner: owner, next_block_to_fetch: next} = cursor, lease, now),
    do: owner == lease.owner and next == lease.next_block and leased?(cursor, now)

  defp apply_plan(cursor, {:range, headers, logs, finality}, bound, now) do
    case divergence(cursor.chain_id, headers) do
      # The old suffix goes, the cursor stays: a late source may have pulled it
      # below the divergence, and the next pass stores the new fork from there
      # rather than skipping the blocks that source was admitted for.
      {:forked, height} ->
        orphan(cursor, height - 1, bound)

      :none ->
        blocks = record_blocks(cursor.chain_id, headers, now)
        stored_logs = record_logs(cursor.chain_id, blocks, logs, now)
        project_launches(stored_logs)
        promote(cursor.chain_id, finality, bound)
        move_to(cursor, List.last(headers).number + 1)
    end
  end

  defp apply_plan(cursor, {:promote, finality}, bound, _now) do
    promote(cursor.chain_id, finality, bound)
    cursor
  end

  defp apply_plan(cursor, {:rewind, ancestor}, bound, _now),
    do: cursor |> orphan(ancestor, bound) |> move_to(ancestor + 1)

  # What the ledger already knows about the headers just fetched. A stored
  # orphan is never revived, so a provider serving an abandoned fork again fails
  # the pass before anything is written. A canonical row at one of these heights
  # under another hash is the new fork's first divergence.
  defp divergence(chain_id, headers) do
    chain_id
    |> stored_blocks(Enum.map(headers, & &1.hash))
    |> Enum.each(&live/1)

    canonical =
      chain_id
      |> canonical_range(hd(headers).number, List.last(headers).number)
      |> by_key(& &1.block_number)

    Enum.find_value(headers, :none, &forked(canonical, &1))
  end

  defp live(%{canonical: true}), do: :ok
  defp live(orphan), do: Repo.rollback({:noncanonical_replay, orphan.block_number})

  defp forked(canonical, header), do: canonical |> Map.get(header.number) |> diverged(header)

  defp diverged(nil, _header), do: nil
  defp diverged(%{block_hash: hash}, %{hash: hash}), do: nil
  defp diverged(_parted, header), do: {:forked, header.number}

  # Only the local suffix is retired: the run of canonical rows that starts at
  # the height just above the ancestor and climbs by stored parent links. The
  # first row is the divergent child, so it names whatever it forked from rather
  # than the ancestor; every row after it must name the one beneath it. A gap or
  # a second linkage break ends the run, and the higher canonical segment past
  # it is left untouched for an ordinary later pass to rediscover.
  defp orphan(cursor, ancestor, bound) do
    cursor.chain_id
    |> suffix(ancestor, bound)
    |> revisable(bound)
    |> Ash.bulk_update!(:mark_noncanonical, %{}, actor: @actor)

    cursor
  end

  defp suffix(chain_id, ancestor, bound) do
    window = canonical_window(chain_id, ancestor + 1, ancestor + bound + 1)

    case Map.get(window, ancestor + 1) do
      nil -> []
      divergent -> [divergent | ascending(window, ancestor + 2, divergent.block_hash)]
    end
  end

  # The bound and finality are both refusals of the whole suffix rather than of
  # part of it: a reorg this deep, or one reaching evidence the provider already
  # called final, is not something to half-apply.
  defp revisable(rows, bound) when length(rows) > bound,
    do: Repo.rollback({:rewind_over_bound, List.last(rows).block_number})

  defp revisable(rows, _bound) do
    Enum.each(rows, &unfinalized/1)
    rows
  end

  defp unfinalized(%{finalized: true, block_number: number}),
    do: Repo.rollback({:finalized_rewind, number})

  defp unfinalized(_revisable), do: :ok

  # Insert-only: the identity decides the duplicate race, and every header in the
  # range must then be stored exactly as the provider just described it. A stored
  # orphan is never revived and a stored promotion is never demoted, because no
  # column of an existing row is written here.
  defp record_blocks(chain_id, headers, now) do
    insert_absent(Block, Enum.map(headers, &block_row(chain_id, &1, now)), [
      :chain_id,
      :block_hash
    ])

    stored = by_key(stored_blocks(chain_id, Enum.map(headers, & &1.hash)), & &1.block_hash)
    Enum.each(headers, &verify_block(Map.fetch!(stored, &1.hash), &1))
    stored
  end

  defp verify_block(%{block_number: number, parent_hash: parent}, %{
         number: number,
         parent_hash: parent
       }),
       do: :ok

  defp verify_block(_stored, header), do: Repo.rollback({:block_conflict, header.number})

  defp record_logs(chain_id, blocks, logs, now) do
    insert_absent(Log, Enum.map(logs, &log_row(chain_id, &1, blocks, now)), [
      :chain_id,
      :block_hash,
      :log_index
    ])

    stored =
      chain_id
      |> stored_logs(Map.keys(blocks))
      |> by_key(&{&1.block_hash, &1.log_index})

    Enum.each(logs, &verify_log(Map.fetch!(stored, {&1.block_hash, &1.log_index}), &1))
    Map.values(stored)
  end

  defp project_launches(logs) do
    case LaunchProjection.project_logs(logs) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp verify_log(
         %{
           transaction_hash: transaction_hash,
           transaction_index: transaction_index,
           address: address,
           topics: topics,
           data: data
         },
         %{
           transaction_hash: transaction_hash,
           transaction_index: transaction_index,
           address: address,
           topics: topics,
           data: data
         }
       ),
       do: :ok

  defp verify_log(_stored, log), do: Repo.rollback({:log_conflict, log.log_index})

  # The provider's exact finalized hash at a height the ledger holds as canonical
  # is necessary but not sufficient: that block is the anchor, and only rows
  # whose stored parent hashes chain it to that anchor are promoted with it. A
  # segment sitting at a promotable height but linked to nothing stays exactly
  # as unfinalized as it was.
  defp promote(chain_id, %{number: number, hash: hash}, bound) do
    case canonical_block(chain_id, number) do
      %{block_hash: ^hash} = anchor -> finalize(chain_id, anchor, bound)
      _unproven -> :ok
    end
  end

  defp finalize(chain_id, anchor, bound) do
    chain_id
    |> connected(anchor, bound)
    |> Ash.bulk_update!(:mark_finalized, %{}, actor: @actor)
  end

  # The first promotion is the anchor and the linked run beneath it. After that
  # the stored segment already carries the anchor's authority, so it grows one
  # bounded step at each end: up toward the anchor as later heights are proven,
  # and down as a late backfill stores the links beneath it. A deep backfill is
  # caught up over several passes rather than in one unbounded promotion.
  defp connected(chain_id, anchor, bound) do
    case finalized_head(chain_id) do
      nil ->
        beneath(chain_id, anchor.block_number, anchor.block_hash, bound)

      head ->
        chain_id
        |> above(head, anchor.block_number, bound)
        |> Enum.concat(beneath_base(chain_id, bound))
    end
  end

  defp above(chain_id, head, ceiling, bound) do
    chain_id
    |> canonical_window(head.block_number + 1, min(head.block_number + bound, ceiling))
    |> ascending(head.block_number + 1, head.block_hash)
  end

  defp beneath_base(chain_id, bound) do
    base = finalized_base(chain_id)
    beneath(chain_id, base.block_number - 1, base.parent_hash, bound)
  end

  defp beneath(chain_id, from, hash, bound) do
    chain_id
    |> canonical_window(from - bound + 1, from)
    |> descending(from, hash)
  end

  # Every step is the stored canonical row the neighbour it came from names, so
  # a gap or a linkage break ends the run rather than carrying it across.
  defp ascending(window, height, linked) do
    case Map.get(window, height) do
      %{parent_hash: ^linked} = row -> [row | ascending(window, height + 1, row.block_hash)]
      _disconnected -> []
    end
  end

  defp descending(window, height, linked) do
    case Map.get(window, height) do
      %{block_hash: ^linked} = row -> [row | descending(window, height - 1, row.parent_hash)]
      _disconnected -> []
    end
  end

  # A bounded height window holds no more canonical rows than heights, because
  # one canonical block per height is a database fact.
  defp canonical_window(chain_id, from, to),
    do: chain_id |> canonical_range(from, to) |> by_key(& &1.block_number)

  defp canonical_range(chain_id, from, to) do
    Block
    |> Ash.Query.for_read(
      :canonical_between,
      %{chain_id: chain_id, from_block_number: from, to_block_number: to},
      actor: @actor
    )
    |> Ash.read!()
  end

  defp finalized_head(chain_id), do: frontier(:finalized_head, chain_id)
  defp finalized_base(chain_id), do: frontier(:finalized_base, chain_id)

  defp frontier(action, chain_id) do
    Block
    |> Ash.Query.for_read(action, %{chain_id: chain_id}, actor: @actor)
    |> Ash.read_one!()
  end

  defp stored_blocks(chain_id, hashes) do
    Block
    |> Ash.Query.for_read(:by_hashes, %{chain_id: chain_id, block_hashes: hashes}, actor: @actor)
    |> Ash.read!()
  end

  defp source(chain_id, address) do
    Source
    |> Ash.Query.for_read(:for_address, %{chain_id: chain_id, address: address}, actor: @actor)
    |> Ash.read_one!()
  end

  defp stored_logs(chain_id, hashes) do
    Log
    |> Ash.Query.for_read(
      :by_block_hashes,
      %{chain_id: chain_id, block_hashes: hashes},
      actor: @actor
    )
    |> Ash.read!()
  end

  defp block_row(chain_id, header, now) do
    %{
      id: Ash.UUID.generate(),
      chain_id: chain_id,
      block_number: header.number,
      block_hash: header.hash,
      parent_hash: header.parent_hash,
      canonical: true,
      finalized: false,
      inserted_at: now,
      updated_at: now
    }
  end

  defp log_row(chain_id, log, blocks, now) do
    %{
      id: Ash.UUID.generate(),
      chain_id: chain_id,
      block_id: Map.fetch!(blocks, log.block_hash).id,
      block_hash: log.block_hash,
      log_index: log.log_index,
      transaction_hash: log.transaction_hash,
      transaction_index: log.transaction_index,
      address: log.address,
      topics: log.topics,
      data: log.data,
      inserted_at: now,
      updated_at: now
    }
  end

  defp move_to(%{next_block_to_fetch: block} = cursor, block), do: cursor

  defp move_to(cursor, block),
    do: Ash.update!(cursor, %{next_block_to_fetch: block}, action: :move_to, actor: @actor)

  # Admission and every commit insert-if-absent before locking, so the
  # absent-row order of a race takes the same lock as the present-row one.
  defp ensure(chain_id, next_block_to_fetch, now) do
    insert_absent(
      Cursor,
      [
        %{
          id: Ash.UUID.generate(),
          chain_id: chain_id,
          next_block_to_fetch: next_block_to_fetch,
          inserted_at: now,
          updated_at: now
        }
      ],
      [:chain_id]
    )
  end

  # The identity's unique index decides every duplicate race; nothing already
  # stored is rewritten, so a replay can only confirm or contradict evidence.
  defp insert_absent(resource, rows, conflict_target) do
    # Ash is bypassed deliberately: this must be one statement that lets the
    # unique index absorb a duplicate silently and writes no column of the row
    # already stored. A create action would raise on that conflict or upsert
    # over it, and upserting is exactly the rewrite this ledger refuses. Every
    # column is built above, so no change or validation is being skipped, and
    # these rows are only ever written from inside this module.
    Repo.insert_all(resource, rows,
      prefix: AshPostgres.DataLayer.Info.schema(resource) || Repo.default_prefix(),
      on_conflict: :nothing,
      conflict_target: conflict_target
    )
  end

  defp lock(chain_id) do
    Cursor
    |> Ash.Query.for_read(:for_chain, %{chain_id: chain_id}, actor: @actor)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!()
  end

  defp by_key(records, key), do: Map.new(records, &{key.(&1), &1})

  # Lease expiry and every stored timestamp are measured by the database, so a
  # skewed application clock cannot extend or shorten an owner's window.
  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT now()")
    now
  end
end
