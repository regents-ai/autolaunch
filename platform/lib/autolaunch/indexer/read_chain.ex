defmodule Autolaunch.Indexer.ReadChain do
  @moduledoc """
  The job that moves one chain's ledger forward.

  Each configured chain has one (`Autolaunch.ChainWatch` makes sure of it),
  unique while it is incomplete, so one run at a time reads a chain. Every
  database and provider read happens in the run, so a failure on one chain
  advances nothing and leaves the other chains and the site running.

  Every run first re-states the chain's configured sources, which is the same
  fact twice for an admitted address and the admission for a new one, so a
  ledger that was never opened for a chain opens on the first run and a
  restored one catches up without keeping any state in the job.

  One bounded contiguous range is planned from the cursor as it stands and
  fetched outside the row lock, then committed only if the cursor is still at
  that exact block and the chain's sources are still the ones it was planned
  from (`Autolaunch.Indexer.Ledger.commit/3`). The range's first header is
  fetched and linked before anything else, so a divergence costs one request
  instead of the whole bound. Finality promotion uses the same bound and runs
  on its own when the safe head has not moved, so evidence can finalize while
  ingest is idle.

  A run keeps passing until the ledger reaches the safe head, then waits five
  minutes; a press that lands on the chain brings it forward to ten seconds
  away (`refresh/1`, from `Autolaunch.ChainRefresh`). A run far behind stops
  after a few dozen passes and runs again a second later, so no run lasts long
  enough to be taken for a stopped one. A run the node could not answer, or
  whose cursor or sources another run moved first, waits a minute; any other
  failure is a fault, tried again a minute later.
  """

  use Oban.Worker,
    queue: :chain,
    max_attempts: 20,
    unique: [keys: [:chain_id], period: :infinity, states: :incomplete]

  @behaviour Autolaunch.ChainRefresh

  require Logger

  alias Autolaunch.ChainWatch
  alias Autolaunch.Indexer.{Chain, Chains, Ledger}

  # One bound serves the ingest range, the reorg walk and the finality batch, so
  # no pass can issue an unbounded number of provider calls or updates.
  @bound 8

  # No work is admitted. That is how a deployment with nothing to watch idles,
  # so it is not a diagnostic.
  @quiet [:no_source_admitted]

  # The node did not answer, or another run (one Lifeline rescued, or a release's
  # outgoing machine) moved the cursor or the sources first.
  @waits [:chain_unavailable, :cursor_moved, :sources_changed]

  # The most passes one run makes: 240 blocks, about eight minutes of Base.
  @passes 30

  @spec bound() :: pos_integer()
  def bound, do: @bound

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"chain_id" => chain_id}}) do
    case read(chain_id) do
      {:ok, _committed} -> {:snooze, 300}
      :behind -> {:snooze, 1}
      {:error, reason} when reason in @quiet -> {:snooze, 300}
      {:error, reason} when reason in @waits -> {:snooze, 60}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: 60

  @doc "Every configured chain's reading job (`Autolaunch.ChainWatch`)."
  def jobs, do: Enum.map(Chains.configured(), &new(%{chain_id: &1.chain_id}))

  @doc """
  A person's on-chain press on chain `chain_id` landed: its ledger, when this
  site keeps one, is read ten seconds from now instead of at its next turn.
  """
  # No job runs while the site is read-only before launch (`Autolaunch.Application`).
  @impl Autolaunch.ChainRefresh
  def refresh(chain_id) do
    if not Autolaunch.Prelaunch.read_only?() and
         Enum.any?(Chains.configured(), &(&1.chain_id == chain_id)),
       do: ChainWatch.soon(new(%{chain_id: chain_id}))

    :ok
  end

  @doc """
  Reads chain `chain_id`'s ledger up to its safe head, one bounded pass after
  another, or `:behind` once it has made its most passes.
  """
  @spec read(pos_integer()) :: {:ok, term()} | :behind | {:error, term()}
  def read(chain_id) do
    case admitted(chain_id) do
      :ok -> caught_up(chain_id, @passes)
      {:error, reason} -> reported({:error, reason}, chain_id)
    end
  end

  defp caught_up(chain_id, passes) do
    case chain_id |> pass() |> reported(chain_id) do
      :behind when passes > 1 -> caught_up(chain_id, passes - 1)
      result -> result
    end
  end

  defp pass(chain_id) do
    case Ledger.cursor(chain_id) do
      nil -> {:error, :no_source_admitted}
      cursor -> advance(cursor)
    end
  end

  defp admitted(chain_id) do
    chain_id
    |> Chains.sources!()
    |> Enum.reduce_while(:ok, fn source, :ok ->
      case Ledger.admit_source(chain_id, source.address, source.start_block) do
        {:ok, _source} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp advance(cursor) do
    with :ok <- Chain.verify_chain(cursor.chain_id),
         {:ok, safe} <- Chain.header(cursor.chain_id, "safe"),
         {:ok, finality} <- Chain.header(cursor.chain_id, "finalized"),
         :ok <- ordered(finality, safe),
         do: plan(cursor, safe, finality)
  end

  # A finalized head above the safe head is two answers from two chains.
  defp ordered(%{number: finalized}, %{number: safe}) when finalized <= safe, do: :ok
  defp ordered(_finality, _safe), do: {:error, :head_disorder}

  defp plan(cursor, safe, finality) do
    :telemetry.execute(
      [:autolaunch, :indexer, :lag],
      %{blocks: max(safe.number - cursor.next_block + 1, 0)},
      %{indexer: :ledger, chain_id: cursor.chain_id}
    )

    case range(cursor.next_block, safe.number) do
      :none -> Ledger.commit(cursor, {:promote, finality}, @bound)
      {from, to} -> cursor |> ingest(from, to, safe, finality) |> behind(to < safe.number)
    end
  end

  defp behind({:ok, _committed}, true), do: :behind
  defp behind(result, _below_safe), do: result

  defp range(from, safe) when from > safe, do: :none
  defp range(from, safe), do: {from, min(safe, from + @bound - 1)}

  defp ingest(cursor, from, to, safe, finality) do
    sources = Ledger.sources(cursor.chain_id)

    with {:ok, first} <- opening(cursor, from, floor_block(sources)),
         {:ok, rest} <- Chain.headers(cursor.chain_id, from + 1, to),
         headers = [first | rest],
         :ok <- contiguous(headers, from),
         :ok <- tipped(List.last(headers), safe),
         {:ok, logs} <- Chain.logs(cursor.chain_id, from, to, Enum.map(sources, & &1.address)),
         :ok <- emitted(logs, headers, sources) do
      Ledger.commit(cursor, {:range, headers, logs, finality, sources}, @bound)
    else
      {:reorg, floor} -> rewind(cursor, from - 1, floor)
      {:error, reason} -> {:error, reason}
    end
  end

  # The range's first header decides whether the stored chain and the provider's
  # chain still agree, so it is fetched and linked before the rest of the range
  # or any log is asked for.
  defp opening(cursor, from, floor) do
    with {:ok, %{number: ^from} = header} <- Chain.header(cursor.chain_id, from),
         :ok <- linked(cursor, header, floor) do
      {:ok, header}
    else
      {:ok, _misplaced} -> {:error, :gapped_range}
      parted -> parted
    end
  end

  # Bootstrap is the absence of a stored predecessor, never a position: a source
  # admitted behind the ledger leaves nothing at that height to link to, and the
  # heights the range does overlap are compared under the commit's own lock.
  defp linked(cursor, header, floor) do
    case Ledger.canonical_block(cursor.chain_id, cursor.next_block - 1) do
      %{block_hash: parent} when parent == header.parent_hash -> :ok
      nil -> :ok
      _parted -> {:reorg, floor}
    end
  end

  # The walk only ever looks backward through the bounded window and never below
  # the earliest admitted source start, so a deep or unrecognisable divergence
  # leaves the ledger untouched instead of guessing a recovery point.
  defp rewind(cursor, from, floor) do
    case ancestor(cursor.chain_id, from, max(from - @bound + 1, floor)) do
      {:ok, height} -> Ledger.commit(cursor, {:rewind, height}, @bound)
      :none -> {:error, :no_common_ancestor}
      aborted -> aborted
    end
  end

  defp ancestor(_chain_id, height, floor) when height < floor, do: :none

  defp ancestor(chain_id, height, floor) do
    case Ledger.canonical_block(chain_id, height) do
      %{block_hash: stored} ->
        compared(chain_id, height, floor, stored, Chain.header(chain_id, height))

      nil ->
        ancestor(chain_id, height - 1, floor)
    end
  end

  # Only a header the provider actually returned is evidence: a transport or
  # malformed answer aborts the walk with that error rather than reading it as
  # divergence, and a fork the ledger already abandoned is never walked into.
  defp compared(_chain_id, height, _floor, stored, {:ok, %{hash: stored}}), do: {:ok, height}
  defp compared(_chain_id, _height, _floor, _stored, {:error, reason}), do: {:error, reason}

  defp compared(chain_id, height, floor, _stored, {:ok, offered}) do
    if Ledger.abandoned?(chain_id, offered.hash),
      do: {:error, {:noncanonical_replay, height}},
      else: ancestor(chain_id, height - 1, floor)
  end

  # The provider must describe one unbroken chain: every height in order and
  # every header naming the one before it as its parent.
  defp contiguous([%{number: from} | _rest] = headers, from) do
    headers
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [%{number: number, hash: hash}, next] ->
      next.number == number + 1 and next.parent_hash == hash
    end)
    |> gapped()
  end

  defp contiguous(_headers, _from), do: {:error, :gapped_range}

  defp gapped(true), do: :ok
  defp gapped(false), do: {:error, :gapped_range}

  # A range that reaches the safe head must end at the exact header the provider
  # named safe, or its two answers came from two different chains.
  defp tipped(%{number: number, hash: hash}, %{number: number, hash: hash}), do: :ok
  defp tipped(%{number: number}, %{number: safe}) when number < safe, do: :ok
  defp tipped(_tip, _safe), do: {:error, :safe_head_mismatch}

  # A log is evidence only where the provider placed it in a header this pass
  # fetched, an admitted address emitted it, and it happened at or after the
  # block that address became interesting at.
  defp emitted(logs, headers, sources) do
    heights = Map.new(headers, &{&1.hash, &1.number})
    starts = Map.new(sources, &{&1.address, &1.start_block})

    logs
    |> Enum.map(&admitted(Map.get(heights, &1.block_hash), Map.get(starts, &1.address)))
    |> Enum.find(:ok, &(&1 != :ok))
  end

  defp admitted(nil, _start), do: {:error, :log_outside_range}
  defp admitted(_height, nil), do: {:error, :unadmitted_emitter}
  defp admitted(height, start) when height < start, do: {:error, :log_before_start}
  defp admitted(_height, _start), do: :ok

  defp floor_block(sources), do: sources |> Enum.map(& &1.start_block) |> Enum.min()

  # One redacted line per failing pass: a method, a chain and a small reason
  # class, never an endpoint, a key or provider payload. Idling quietly is not
  # a failure and says nothing at all.
  defp reported(:behind, _chain_id), do: :behind
  defp reported({:ok, _committed} = advanced, _chain_id), do: advanced
  defp reported({:error, reason} = idle, _chain_id) when reason in @quiet, do: idle

  defp reported({:error, reason}, chain_id) do
    Logger.warning("autolaunch indexer #{inspect(%{chain_id: chain_id, reason: reason})}")
    {:error, reason}
  end
end
