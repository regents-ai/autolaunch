defmodule Autolaunch.IndexerCase do
  @moduledoc """
  Real committed rows and real separate connections for the Base log ledger.

  The ledger's ordering is decided by PostgreSQL row locks across connections,
  so a sandbox transaction no second connection could see would prove nothing.
  These tests run unboxed and remove exactly the ledger rows they minted, and
  they wait on lock state and messages rather than on elapsed time.
  """

  use ExUnit.CaseTemplate

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  require Ash.Query

  alias Autolaunch.Indexer.{Block, Cursor, Handler, Log, Source}
  alias Autolaunch.Repo
  alias Autolaunch.TestAutolaunchIndexerChainClient, as: Endpoint

  @chain_id 8453
  @ledger_tables [Log, Block, Source, Cursor]

  using do
    quote do
      import Autolaunch.IndexerCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    clear_ledger()
    on_exit(&clear_ledger/0)
    :ok
  end

  @doc "Runs `attempt` on a real connection whose writes other connections can see."
  def unboxed(attempt), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, attempt)

  @doc "Starts the fake Base endpoint answering from `chain` for this test."
  def start_endpoint(chain), do: ExUnit.Callbacks.start_supervised!({Endpoint, chain})

  def chain_id, do: @chain_id

  ## The scripted chain

  @doc "A chain the fake endpoint answers from, safe and finalized heads included."
  def chain(blocks, opts \\ []) do
    %{
      blocks: blocks,
      chain_id: Keyword.get(opts, :chain_id, "0x2105"),
      safe: Keyword.get(opts, :safe, List.last(blocks).number),
      safe_hash: Keyword.get(opts, :safe_hash),
      finalized: Keyword.get(opts, :finalized, hd(blocks).number),
      fault: Keyword.get(opts, :fault),
      filter_addresses: Keyword.get(opts, :filter_addresses, true)
    }
  end

  @doc "Contiguous headers over `range`, taking each height's fork label from `forks`."
  def blocks(range, forks \\ %{}) do
    Enum.map(range, fn number ->
      %{
        number: number,
        hash: block_hash(number, fork_at(forks, number)),
        parent: block_hash(number - 1, fork_at(forks, number - 1)),
        logs: []
      }
    end)
  end

  @doc "A fork label applied to every height in `range`."
  def fork(range, label), do: Map.new(range, &{&1, label})

  @doc "Places `specs` as the logs the block at `number` emitted."
  def emit(blocks, number, specs) do
    Enum.map(blocks, fn
      %{number: ^number} = block -> %{block | logs: Enum.map(specs, &log(block, &1))}
      block -> block
    end)
  end

  @doc "The deterministic hash of one height on one fork."
  def block_hash(number, label \\ "a"), do: digest("block:#{label}:#{number}")

  @doc "The deterministic hash of one transaction."
  def transaction_hash(number, index), do: digest("transaction:#{number}:#{index}")

  @doc "The deterministic hash of one topic."
  def topic(name), do: digest("topic:#{name}")

  ## Driving the handler

  @doc "Admits one watched address at `start_block` through its private action."
  def admit(address, start_block),
    do: unboxed(fn -> Handler.admit_source(address, start_block) end)

  @doc "One durable-work pass, exactly as the runner would dispatch it."
  def pass, do: unboxed(fn -> Handler.handle(nil, @chain_id) end)

  ## Reading the committed ledger

  def cursor, do: unboxed(fn -> read_one(Cursor, :for_chain, %{chain_id: @chain_id}) end)

  def sources do
    unboxed(fn ->
      Source
      |> Ash.Query.for_read(:for_chain, %{chain_id: @chain_id}, actor: actor())
      |> Ash.read!()
    end)
  end

  def stored_blocks do
    unboxed(fn ->
      Block
      |> Ash.Query.for_read(:read, %{}, actor: actor())
      |> Ash.Query.sort(block_number: :asc, block_hash: :asc)
      |> Ash.read!()
    end)
  end

  def stored_logs do
    unboxed(fn ->
      Log
      |> Ash.Query.for_read(
        :by_block_hashes,
        %{chain_id: @chain_id, block_hashes: Enum.map(stored_headers(), & &1.block_hash)},
        actor: actor()
      )
      |> Ash.Query.sort(block_hash: :asc, log_index: :asc)
      |> Ash.read!()
    end)
  end

  @doc "Every stored block number the ledger has promoted to finalized."
  def finalized, do: stored_blocks() |> Enum.filter(& &1.finalized) |> Enum.map(& &1.block_number)

  @doc "Every stored block number the ledger holds as an abandoned fork."
  def orphaned, do: stored_blocks() |> Enum.reject(& &1.canonical) |> Enum.map(& &1.block_number)

  @doc "Whether the block stored under `hash` is still canonical."
  def canonical?(hash), do: Enum.find(stored_blocks(), &(&1.block_hash == hash)).canonical

  def actor, do: %Autolaunch.Actors.System{}

  ## Forcing an order between two real connections

  @doc "Holds `attempt`'s row lock open on its own connection until `release/1`."
  def holding(attempt) do
    test = self()
    task = Task.async(fn -> unboxed(fn -> hold(attempt, test) end) end)

    assert_receive {:holding, holder, backend}, 5_000
    {task, holder, backend}
  end

  def release({task, holder, _backend}) do
    send(holder, :release)
    {:ok, result} = Task.await(task, 15_000)
    result
  end

  @doc "Starts `attempt` on a second connection and announces its backend."
  def contending(attempt) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:contending, backend_pid()})
          send(test, {:settled, attempt.()})
        end)
      end)

    assert_receive {:contending, backend}, 5_000
    {task, backend}
  end

  def settled({task, _backend}) do
    assert_receive {:settled, result}, 15_000
    Task.await(task, 15_000)
    result
  end

  @doc "PostgreSQL itself reports the ordering, so no sleep decides the race."
  def assert_blocked_by({_task, contender}, {_holder_task, _holder, holder}) do
    assert Enum.reduce_while(1..2_000, false, fn _attempt, _blocked ->
             if holder in blocking_pids(contender), do: {:halt, true}, else: {:cont, false}
           end),
           "the contender never blocked on the held cursor lock"
  end

  defp backend_pid do
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  # Removes exactly the ledger rows these tests mint, dependent rows first.
  # No ledger resource exposes a destroy action, and teardown has to clear rows
  # a half-finished test committed, so this deletes at the table directly.
  defp clear_ledger,
    do: unboxed(fn -> Enum.each(@ledger_tables, &Repo.delete_all(scoped(&1))) end)

  defp scoped(resource),
    do: from(row in resource, prefix: ^AshPostgres.DataLayer.Info.schema(resource))

  defp blocking_pids(backend) do
    unboxed(fn ->
      %{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend])
      blockers
    end)
  end

  defp hold(attempt, test), do: Repo.transaction(fn -> hold_open(attempt, test) end)

  defp hold_open(attempt, test) do
    result = attempt.()
    send(test, {:holding, self(), backend_pid()})
    receive do: (:release -> result)
  end

  defp stored_headers, do: unboxed(fn -> Ash.read!(Block, actor: actor()) end)

  defp read_one(resource, action, input),
    do: resource |> Ash.Query.for_read(action, input, actor: actor()) |> Ash.read_one!()

  defp log(block, spec) do
    %{
      "blockHash" => block.hash,
      "logIndex" => hex(spec.index),
      "transactionHash" => transaction_hash(block.number, spec.index),
      "transactionIndex" => hex(Map.get(spec, :transaction_index, 0)),
      "address" => spec.address,
      "topics" => Map.get(spec, :topics, [topic("launch")]),
      "data" => Map.get(spec, :data, "0x"),
      "removed" => Map.get(spec, :removed, false)
    }
  end

  defp fork_at(forks, number), do: Map.get(forks, number, "a")
  defp digest(seed), do: "0x" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
  defp hex(number), do: "0x" <> String.downcase(Integer.to_string(number, 16))
end
