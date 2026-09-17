defmodule Autolaunch.Indexer.Handler do
  @moduledoc """
  The one durable-work item that moves one chain's ledger forward.

  Each configured chain has its own runner whose context is the chain id.
  `poll/2` is pure: it names that chain and nothing else, so every database and
  provider read happens in the runner's monitored handler process and a failure
  on one chain advances nothing and takes neither the runner, another chain, the
  repository nor the application supervisor with it.

  Every pass first re-states the chain's configured sources, which is the same
  fact twice for an admitted address and the admission for a new one, so a
  ledger that was never opened for a chain opens on the first pass and a
  restored one catches up without keeping any state in this process.

  One bounded contiguous range is planned from the exact cursor the lease was
  granted at and fetched outside the row lock, then committed only if that same
  lease and that same cursor are still true. The range's first header is fetched
  and linked before anything else, so a divergence costs one request instead of
  the whole bound. Finality promotion uses the same bound and runs on its own
  when the safe head has not moved, so evidence can finalize while ingest is
  idle.
  """

  @behaviour Autolaunch.DurableWork.Handler

  require Logger

  alias Autolaunch.Indexer.{Chain, Chains, Ledger, Rpc}

  # One bound serves the ingest range, the reorg walk and the finality batch, so
  # no handler pass can issue an unbounded number of provider calls or updates.
  @bound 8

  # The requests a pass makes outside the bound: the chain id, the safe head,
  # the finalized head, and then either the range's log query or, on the reorg
  # path, the first header that revealed the divergence.
  @outside 4

  # What the commit following the last provider answer is allowed to take.
  @commit_margin_ms 10_000

  # No work is admitted, or another instance owns the chain. Both are how a
  # healthy deployment idles, so neither is a diagnostic.
  @quiet [:no_source_admitted, :leased]

  @spec bound() :: pos_integer()
  def bound, do: @bound

  @doc "The most provider requests one pass can issue, on either path."
  @spec max_requests() :: pos_integer()
  def max_requests, do: @bound + @outside

  @doc """
  How long a granted lease lasts, derived from the work it admits.

  Nothing renews it mid-pass, so it must outlive every request the bound permits
  at the enforced wall-clock deadline the transport boundary owns, plus the
  commit after the last answer.
  """
  @spec lease_ms() :: pos_integer()
  def lease_ms, do: max_requests() * Rpc.max_request_ms() + @commit_margin_ms

  @impl true
  def poll(_chain_id, 0), do: []
  def poll(chain_id, _capacity), do: [chain_id]

  @impl true
  def handle(_context, chain_id) do
    with :ok <- admitted(chain_id),
         {:ok, lease} <- Ledger.acquire(chain_id, lease_ms()) do
      reported(leased(lease), chain_id)
    else
      {:error, reason} -> reported({:error, reason}, chain_id)
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

  defp leased(lease) do
    advance(lease)
  after
    Ledger.release(lease)
  end

  defp advance(lease) do
    with :ok <- Chain.verify_chain(lease.chain_id),
         {:ok, safe} <- Chain.header(lease.chain_id, "safe"),
         {:ok, finality} <- Chain.header(lease.chain_id, "finalized"),
         :ok <- ordered(finality, safe),
         do: plan(lease, safe, finality)
  end

  # A finalized head above the safe head is two answers from two chains.
  defp ordered(%{number: finalized}, %{number: safe}) when finalized <= safe, do: :ok
  defp ordered(_finality, _safe), do: {:error, :head_disorder}

  defp plan(lease, safe, finality) do
    case range(lease.next_block, safe.number) do
      :none -> Ledger.commit(lease, {:promote, finality}, @bound)
      {from, to} -> ingest(lease, from, to, safe, finality)
    end
  end

  defp range(from, safe) when from > safe, do: :none
  defp range(from, safe), do: {from, min(safe, from + @bound - 1)}

  defp ingest(lease, from, to, safe, finality) do
    sources = Ledger.sources(lease.chain_id)

    with {:ok, first} <- opening(lease, from, floor_block(sources)),
         {:ok, rest} <- Chain.headers(lease.chain_id, from + 1, to),
         headers = [first | rest],
         :ok <- contiguous(headers, from),
         :ok <- tipped(List.last(headers), safe),
         {:ok, logs} <- Chain.logs(lease.chain_id, from, to, Enum.map(sources, & &1.address)),
         :ok <- emitted(logs, headers, sources) do
      Ledger.commit(lease, {:range, headers, logs, finality}, @bound)
    else
      {:reorg, floor} -> rewind(lease, from - 1, floor)
      {:error, reason} -> {:error, reason}
    end
  end

  # The range's first header decides whether the stored chain and the provider's
  # chain still agree, so it is fetched and linked before the rest of the range
  # or any log is asked for.
  defp opening(lease, from, floor) do
    with {:ok, %{number: ^from} = header} <- Chain.header(lease.chain_id, from),
         :ok <- linked(lease, header, floor) do
      {:ok, header}
    else
      {:ok, _misplaced} -> {:error, :gapped_range}
      parted -> parted
    end
  end

  # Bootstrap is the absence of a stored predecessor, never a position: a source
  # admitted behind the ledger leaves nothing at that height to link to, and the
  # heights the range does overlap are compared under the commit's own lock.
  defp linked(lease, header, floor) do
    case Ledger.canonical_block(lease.chain_id, lease.next_block - 1) do
      %{block_hash: parent} when parent == header.parent_hash -> :ok
      nil -> :ok
      _parted -> {:reorg, floor}
    end
  end

  # The walk only ever looks backward through the bounded window and never below
  # the earliest admitted source start, so a deep or unrecognisable divergence
  # leaves the ledger untouched instead of guessing a recovery point.
  defp rewind(lease, from, floor) do
    case ancestor(lease.chain_id, from, max(from - @bound + 1, floor)) do
      {:ok, height} -> Ledger.commit(lease, {:rewind, height}, @bound)
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
  defp reported({:ok, _committed} = advanced, _chain_id), do: advanced
  defp reported({:error, reason} = idle, _chain_id) when reason in @quiet, do: idle

  defp reported({:error, reason}, chain_id) do
    Logger.warning("autolaunch indexer #{inspect(%{chain_id: chain_id, reason: reason})}")
    {:error, reason}
  end
end
