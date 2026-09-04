defmodule Autolaunch.LaunchOperationsTest do
  @moduledoc """
  The locked launch lifecycle: who may dispatch, which hash may bind, what a
  receipt is allowed to settle, and what a concurrent logout or a second socket
  may do to any of it.
  """

  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.LaunchFixture, as: Fixture
  alias Autolaunch.LaunchOperations
  alias Autolaunch.TestAutolaunchLaunchChainClient, as: ChainClient
  alias Autolaunch.TestAutolaunchTreasuryChainClient, as: TreasuryClient

  @approval_hash "0x" <> String.duplicate("a1", 32)

  setup do
    Fixture.install()
    context = Fixture.actor()
    TreasuryClient.seed_verified!(Fixture.treasury())

    on_exit(fn ->
      Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
    end)

    context
  end

  describe "ONE_WINNER_PER_DISPATCH: the database decides every race" do
    test "two sockets claiming one dispatch produce exactly one winner", context do
      {:ok, operation} = review(context)

      results = race(fn -> claim(context, operation) end, 2)

      assert Enum.count(results, &match?({:ok, %{operation: %{state: :dispatched}}}, &1)) == 1
      assert Enum.count(results, &match?({:error, _refused}, &1)) == 1
    end

    test "a claimed step is never offered a second dispatch", context do
      {:ok, operation} = review(context)

      assert {:ok, %{operation: %{state: :dispatched}}} = claim(context, operation)
      assert {:error, _refused} = claim(context, operation)
    end

    test "a bound hash never becomes resendable, whichever call lands first", context do
      {:ok, operation} = review(context)
      assert {:ok, _claimed} = claim(context, operation)

      [bound, released] =
        race_each([
          fn -> bind(context, operation, :approval, @approval_hash) end,
          fn -> release(context, operation) end
        ])

      assert {:ok, %{operation: current}} = open(context)

      case current.approval_transaction_hash do
        nil ->
          assert current.state == :prepared
          assert match?({:error, _refused}, bound)

        @approval_hash ->
          assert current.state == :submitted
          assert match?({:error, _refused}, released)
      end
    end

    test "terminal settlement races return the row's own winning outcome", context do
      {:ok, operation} = submitted_approval(context)

      ChainClient.put(%{outcomes: %{approval: %{outcome: :reverted}}})
      results = race(fn -> verify(context, operation) end, 2)

      assert Enum.all?(results, &match?({:ok, %{operation: %{state: :reverted}}}, &1))
      assert {:ok, %{operation: nil}} = open(context)
    end

    test "a read that answered about a row another socket has moved is dropped", context do
      {:ok, operation} = submitted_approval(context)

      ChainClient.put(%{
        outcomes: %{approval: %{outcome: :confirmed}},
        raced: fn -> start_new(context, operation) end
      })

      assert {:ok, %{operation: settled}} = verify(context, operation)

      # The account ended it between the read and the lock, so the read's own
      # answer is not applied to a row it no longer described.
      assert settled.state == :submission_unknown
    end

    test "a dispatch whose fresh read answered about a moved row is refused, not applied",
         context do
      {:ok, operation} = review(context)

      ChainClient.put(%{raced: fn -> cancel(context, operation) end})

      # The snapshot happens outside the transaction, so the row can move under
      # it; the locked row is then not the candidate that read was about.
      assert {:error, refused} = claim(context, operation)
      assert Fixture.refusal(refused) in [:launch_step_moved, :launch_operation_not_found]
      assert {:ok, %{state: :cancelled}} = stored(context, operation)
    end
  end

  describe "THE_MUTATING_FETCH_IS_LOCKED: the transition boundary really emits FOR UPDATE" do
    test "cancelling a review takes that account's own operation row FOR UPDATE", context do
      {:ok, operation} = review(context)

      emitted =
        captured(fn ->
          assert {:ok, %{operation: %{state: :cancelled}}} =
                   Autolaunch.cancel_launch_review(operation.action_id, context[:opts])
        end)

      # The lease locks its own session-authority and account rows in the same
      # transaction, so the operation table's read is named specifically rather
      # than proved by any lock happening somewhere.
      assert [read] = selects(emitted, "launch_operations")
      assert read =~ "FOR UPDATE"
    end

    test "recovering the open launch writes nothing and locks nothing", context do
      {:ok, _operation} = review(context)

      emitted = captured(fn -> assert {:ok, %{operation: %{}}} = open(context) end)

      assert [read] = selects(emitted, "launch_operations")
      refute read =~ "FOR UPDATE"
      assert Enum.all?(emitted, fn {_source, query} -> String.starts_with?(query, "SELECT") end)
    end
  end

  describe "STALE_LOGOUT_WRITES_NOTHING: no durable write outlives its own authority" do
    # Revoke first, then write: the write is refused inside its own transaction.
    test "a revoked lease refuses the very next durable write", context do
      {:ok, operation} = review(context)
      assert SessionAuthority.revoke(claim_of(context))

      assert Fixture.refusal(claim(context, operation)) == :session_unavailable
      assert Fixture.refusal(review(context)) == :session_unavailable
      assert Fixture.refusal(open(context)) == :session_unavailable
    end

    # Write first, then revoke: everything the committed write wrote survives,
    # and the account simply cannot write again.
    test "a write that commits before a logout keeps every fact it wrote", context do
      {:ok, operation} = review(context)

      assert {:ok, %{operation: claimed}} = claim(context, operation)
      assert claimed.state == :dispatched

      assert SessionAuthority.revoke(claim_of(context))

      assert Fixture.refusal(open(context)) == :session_unavailable
      assert {:ok, %{state: :dispatched}} = stored(context, operation)
    end
  end

  describe "RECOVERY_NEEDS_THE_CURRENT_LEASE: an open launch is a private fact" do
    test "a caller carrying no lease at all is refused and names nothing", context do
      {:ok, operation} = review(context)

      assert {:error, error} =
               Autolaunch.open_launch_operation(Keyword.delete(context[:opts], :context))

      assert Fixture.refusal(error) == :session_lease_required
      assert leaked(error, operation) == []
    end

    test "a lease held for another account recovers nothing", context do
      {:ok, operation} = review(context)
      other = Fixture.actor()

      mismatched = Keyword.put(context[:opts], :context, other[:opts][:context])

      assert {:error, error} = Autolaunch.open_launch_operation(mismatched)
      assert Fixture.refusal(error) == :session_unavailable
      assert leaked(error, operation) == []

      # The other account's own lease answers about the other account alone.
      assert {:ok, %{operation: nil}} = Autolaunch.open_launch_operation(other[:opts])
    end
  end

  # Helpers

  defp review(context) do
    with {:ok, %{operation: operation}} <-
           Autolaunch.prepare_launch(context[:draft].id, Fixture.wallet(), context[:opts]),
         do: {:ok, operation}
  end

  defp claim(context, operation),
    do: Autolaunch.claim_launch_dispatch(operation.action_id, Fixture.wallet(), context[:opts])

  defp bind(context, operation, step, hash),
    do: Autolaunch.bind_launch_hash(operation.action_id, step, hash, context[:opts])

  defp verify(context, operation),
    do: Autolaunch.verify_launch_step(operation.action_id, context[:opts])

  defp release(context, operation),
    do: Autolaunch.release_unstarted_launch_dispatch(operation.action_id, context[:opts])

  defp cancel(context, operation),
    do: Autolaunch.cancel_launch_review(operation.action_id, context[:opts])

  defp start_new(context, operation),
    do: Autolaunch.start_new_launch(operation.action_id, context[:opts])

  defp open(context), do: Autolaunch.open_launch_operation(context[:opts])

  defp stored(context, operation),
    do: LaunchOperations.fetch(context[:account].id, operation.action_id, false)

  defp submitted_approval(context) do
    {:ok, operation} = review(context)
    {:ok, _claimed} = claim(context, operation)
    {:ok, _bound} = bind(context, operation, :approval, @approval_hash)
    {:ok, operation}
  end

  defp claim_of(context),
    do: %{lineage: context[:opts][:context][:session_lease][:lineage], generation: 0}

  # A refusal may not carry one fact of the launch it declined to answer about:
  # not its identity, not its signer, not its reviewed bytes.
  defp leaked(error, operation) do
    rendered = inspect(error, limit: :infinity, printable_limit: :infinity)

    Enum.filter(
      [
        operation.action_id,
        operation.signer,
        hd(operation.envelope["arguments"]["steps"])["data"]
      ],
      &String.contains?(rendered, &1)
    )
  end

  # The SQL a real public transition actually emitted, taken from the
  # repository's own telemetry rather than rebuilt from a query this test wrote.
  defp captured(work) do
    parent = self()
    handler = "launch-sql-#{Elixir.System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:autolaunch, :repo, :query],
      fn _event, _measurements, metadata, owner ->
        if self() == owner, do: send(owner, {:sql, metadata[:source], metadata.query})
      end,
      parent
    )

    work.()
    :telemetry.detach(handler)
    drained([])
  end

  defp drained(collected) do
    receive do
      {:sql, source, query} -> drained([{source, query} | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  defp selects(emitted, table) do
    for {^table, query} <- emitted, String.starts_with?(query, "SELECT"), do: query
  end

  # These tasks are allowed onto the test's own sandboxed connection, so they
  # share it and their statements take turns rather than running in parallel.
  # What the barrier proves is that two callers arriving at the same step in
  # either order still produce exactly one winner; the `FOR UPDATE` proof above
  # is what shows the row itself is locked while that happens.
  defp race(work, count), do: race_each(List.duplicate(work, count))

  defp race_each(works) do
    parent = self()
    barrier = :erlang.unique_integer()

    works
    |> Enum.map(fn work ->
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Autolaunch.Repo, parent, self())
        send(parent, {:ready, barrier, self()})

        receive do
          {:go, ^barrier} -> work.()
        end
      end)
    end)
    |> started(barrier)
    |> Enum.map(&Task.await(&1, 15_000))
  end

  defp started(tasks, barrier) do
    for _task <- tasks do
      receive do
        {:ready, ^barrier, pid} -> send(pid, {:go, barrier})
      end
    end

    tasks
  end
end
