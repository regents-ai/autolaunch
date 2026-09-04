defmodule Autolaunch.Indexer.FrontierPlanTest do
  @moduledoc """
  That the ledger's steady frontier reads are served by indexes rather than by
  work proportional to the retained ledger.

  Protects BOUNDED_INDEXED_FRONTIER. Every plan here is taken from the read
  action the ledger actually issues, against a populated ledger whose planner
  statistics have just been refreshed and whose planner settings are untouched,
  so what PostgreSQL is shown choosing is what it would really choose. Only the
  node and the index it reads through are asserted: costs and row estimates are
  the planner's own business and no part of this contract.
  """

  use Autolaunch.IndexerCase, async: false

  require Ash.Query

  alias Autolaunch.Indexer.{Block, Handler}
  alias Autolaunch.Repo

  # Enough retained ledger that a sequential scan is a real option, so choosing
  # an index is a decision the planner made rather than the only thing it could
  # do. Finality lags ingest, which is why the two ends differ.
  @retained 5_000
  @finalized_through 4_800

  setup do
    populate()
    :ok
  end

  test "both ends of the finalized segment are found through the frontier index" do
    for action <- [:finalized_head, :finalized_base] do
      plan = plan(action, %{chain_id: chain_id()})

      assert plan =~ ~r/Index Scan (Backward )?using indexer_blocks_finalized_frontier_index/
      refute plan =~ "Seq Scan"
    end
  end

  test "a bounded canonical height window is read through the canonical height index" do
    ancestor = @finalized_through + 1

    plan =
      plan(:canonical_between, %{
        chain_id: chain_id(),
        from_block_number: ancestor + 1,
        to_block_number: ancestor + Handler.bound() + 1
      })

    assert plan =~ ~r/Index Scan using indexer_blocks_canonical_height_index/
    refute plan =~ "Seq Scan"
  end

  defp plan(action, input) do
    {:ok, query} =
      Block
      |> Ash.Query.for_read(action, input, actor: actor())
      |> Ash.Query.data_layer_query(actor: actor())

    {sql, params} =
      query
      |> Ecto.Query.put_query_prefix(schema())
      |> then(&Repo.to_sql(:all, &1))

    unboxed(fn ->
      %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
      rows |> List.flatten() |> Enum.join("\n")
    end)
  end

  defp populate do
    unboxed(fn ->
      now = DateTime.utc_now()

      1..@retained
      |> Enum.map(&row(&1, now))
      |> Enum.chunk_every(1_000)
      # Ash is bypassed on purpose: these rows are only ballast for the planner, and
      # ingesting five thousand of them through actions would dominate the test.
      |> Enum.each(&Repo.insert_all(Block, &1, prefix: schema()))

      Repo.query!("ANALYZE indexer_blocks")
    end)
  end

  defp row(number, now) do
    %{
      id: Ash.UUID.generate(),
      chain_id: chain_id(),
      block_number: number,
      block_hash: block_hash(number),
      parent_hash: block_hash(number - 1),
      canonical: true,
      finalized: number <= @finalized_through,
      inserted_at: now,
      updated_at: now
    }
  end

  defp schema, do: AshPostgres.DataLayer.Info.schema(Block)
end
