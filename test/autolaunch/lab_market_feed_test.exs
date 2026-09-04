defmodule Autolaunch.LabMarketFeedTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch
  alias Autolaunch.Actors.System, as: SystemActor
  alias Autolaunch.{Auction, LabMarketFeed, LabProjection}

  @lab_address "0x1111111111111111111111111111111111111111"
  @other_address "0x2222222222222222222222222222222222222222"
  @hash_a "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @hash_b "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  defmodule FakeRuntime do
    def install(state) do
      Agent.start_link(fn ->
        Map.merge(
          %{
            head_calls: 0,
            snapshot_calls: 0,
            snapshot_attempts: 0,
            project_calls: 0,
            verify_calls: 0
          },
          state
        )
      end)
    end

    def state(agent), do: Agent.get(agent, & &1)

    def put(agent, values), do: Agent.update(agent, &Map.merge(&1, Map.new(values)))
  end

  defmodule FakeReader do
    def head do
      Agent.get_and_update(agent(), fn state ->
        {state.head, Map.update!(state, :head_calls, &(&1 + 1))}
      end)
    end

    def snapshots(_head, _capacity, attempted_addresses) do
      Agent.get_and_update(agent(), fn state ->
        {result, attempts} = snapshot_result(state.snapshots, attempted_addresses)

        next_state =
          state
          |> Map.update!(:snapshot_calls, &(&1 + 1))
          |> Map.update!(:snapshot_attempts, &(&1 + attempts))

        {result, next_state}
      end)
    end

    def verify_head(expected) do
      Agent.get_and_update(agent(), fn state ->
        {result, state} = configured_verification(state, expected)

        {result, Map.update!(state, :verify_calls, &(&1 + 1))}
      end)
    end

    defp configured_verification(%{verify_results: [result | rest]} = state, _expected),
      do: {result, %{state | verify_results: rest}}

    defp configured_verification(state, expected) do
      case Map.get(state, :verify_result) do
        nil -> {verify_current_head(state, expected), state}
        configured -> {configured, state}
      end
    end

    defp snapshot_result({:ok, snapshots}, attempted_addresses) do
      observed = MapSet.new(snapshots, &String.downcase(&1.auction_address))

      pending =
        Enum.reject(snapshots, fn snapshot ->
          MapSet.member?(attempted_addresses, String.downcase(snapshot.auction_address))
        end)

      result =
        {:ok, %{snapshots: pending, attempted: MapSet.union(attempted_addresses, observed)}}

      {result, length(pending)}
    end

    defp snapshot_result({:error, reason, addresses}, attempted_addresses) do
      observed = MapSet.new(addresses, &String.downcase/1)
      pending = MapSet.difference(observed, attempted_addresses)
      attempted = MapSet.union(attempted_addresses, observed)

      if MapSet.size(pending) == 0,
        do: {{:ok, %{snapshots: [], attempted: attempted}}, 0},
        else: {{:error, reason, attempted}, MapSet.size(pending)}
    end

    defp verify_current_head(state, expected) do
      with {:ok, binding} <- state.current_binding,
           {:ok, %{block: block}} <- state.head do
        current = %{binding: binding, block: block}

        if current.binding == expected.binding and current.block == expected.block,
          do: :ok,
          else: {:error, {:head_changed, current}}
      end
    end

    defp agent, do: Application.fetch_env!(:autolaunch, :lab_market_feed_test_agent)
  end

  defmodule FakeProjector do
    def project(_snapshots, _head) do
      result =
        Agent.get_and_update(agent(), fn state ->
          next_state = Map.update!(state, :project_calls, &(&1 + 1))

          next_state =
            case Map.get(state, :binding_after_project) do
              nil -> next_state
              binding -> Map.put(next_state, :current_binding, {:ok, binding})
            end

          {state.project_result, next_state}
        end)

      if result == :raise, do: raise("projection failed"), else: result
    end

    defp agent, do: Application.fetch_env!(:autolaunch, :lab_market_feed_test_agent)
  end

  defmodule TransactionVerifier do
    def verify_head(_head) do
      Application.fetch_env!(:autolaunch, :lab_market_transaction_verify_result)
    end
  end

  setup do
    Application.put_env(:autolaunch, :lab_market_transaction_verify_result, :ok)

    on_exit(fn ->
      Application.delete_env(:autolaunch, :lab_market_feed_test_agent)
      Application.delete_env(:autolaunch, :lab_market_transaction_verify_result)
    end)

    :ok
  end

  test "the named watcher read excludes an address-bearing non-lab auction" do
    actor = %SystemActor{}
    lab_id = LabProjection.auction_id(@lab_address)

    lab =
      Auction
      |> Ash.Changeset.for_create(
        :project_lab,
        %{
          projection_id: lab_id,
          title: "Local auction",
          featured: false,
          state: :active,
          auction_address: @lab_address,
          creator_human_account_id: Autolaunch.TestSupport.register_creator!().id
        },
        actor: actor,
        domain: Autolaunch
      )
      |> Ash.create!(actor: actor, domain: Autolaunch)

    Autolaunch.TestSupport.project_auction(
      title: "Base-shaped row",
      featured: false,
      state: :active
    )
    |> Autolaunch.set_auction_bid_terms!(@other_address, @other_address, "REGENT", 18, "1",
      actor: actor
    )

    assert {:ok, [watchable]} = Autolaunch.list_lab_market_auctions(actor: actor)
    assert watchable.id == lab.id
    assert watchable.auction_address == @lab_address
    assert {:error, %Ash.Error.Forbidden{}} = Autolaunch.list_lab_market_auctions()
  end

  test "the real projector updates only changed existing fields inside the named Ash boundary" do
    actor = %SystemActor{}
    id = LabProjection.auction_id(@lab_address)

    auction =
      Auction
      |> Ash.Changeset.for_create(
        :project_lab,
        %{
          projection_id: id,
          title: "Projected market",
          featured: false,
          state: :active,
          auction_address: @lab_address,
          current_clearing_price: "1",
          creator_human_account_id: Autolaunch.TestSupport.register_creator!().id
        },
        actor: actor,
        domain: Autolaunch
      )
      |> Ash.create!(actor: actor, domain: Autolaunch)

    block = %{number: 101, hash: @hash_b}
    market = snapshot(id, block, current_clearing_price: "2")
    head = %{block: block}

    assert {:ok, [^id]} = LabMarketFeed.Projector.project([market], head, TransactionVerifier)
    assert {:ok, refreshed} = Autolaunch.get_public_auction(auction.id)
    assert refreshed.current_clearing_price == "2"
    assert refreshed.state == :active

    assert {:ok, []} = LabMarketFeed.Projector.project([market], head, TransactionVerifier)

    assert {:error, %Ash.Error.Forbidden{}} =
             Autolaunch.refresh_lab_market_auction(refreshed, :graduated, "3")
  end

  test "a late projection failure rolls back an earlier row update" do
    actor = %SystemActor{}

    [{existing_id, existing_address}, {missing_id, missing_address}] =
      [
        {LabProjection.auction_id(@lab_address), @lab_address},
        {LabProjection.auction_id(@other_address), @other_address}
      ]
      |> Enum.sort_by(&elem(&1, 0))

    Auction
    |> Ash.Changeset.for_create(
      :project_lab,
      %{
        projection_id: existing_id,
        title: "Rollback market",
        featured: false,
        state: :active,
        auction_address: existing_address,
        current_clearing_price: "1",
        creator_human_account_id: Autolaunch.TestSupport.register_creator!().id
      },
      actor: actor,
      domain: Autolaunch
    )
    |> Ash.create!(actor: actor, domain: Autolaunch)

    block = %{number: 101, hash: @hash_b}

    snapshots = [
      snapshot(existing_id, block,
        auction_address: existing_address,
        current_clearing_price: "2"
      ),
      snapshot(missing_id, block,
        auction_address: missing_address,
        current_clearing_price: "3"
      )
    ]

    assert {:error, :lab_auction_not_found} =
             LabMarketFeed.Projector.project(snapshots, %{block: block}, TransactionVerifier)

    assert {:ok, unchanged} = Autolaunch.get_public_auction(existing_id)
    assert unchanged.current_clearing_price == "1"
  end

  test "the real projector rolls back writes when its in-transaction head check changes" do
    actor = %SystemActor{}
    id = LabProjection.auction_id(@lab_address)

    Auction
    |> Ash.Changeset.for_create(
      :project_lab,
      %{
        projection_id: id,
        title: "Transaction head guard",
        featured: false,
        state: :active,
        auction_address: @lab_address,
        current_clearing_price: "1",
        creator_human_account_id: Autolaunch.TestSupport.register_creator!().id
      },
      actor: actor,
      domain: Autolaunch
    )
    |> Ash.create!(actor: actor, domain: Autolaunch)

    block = %{number: 101, hash: @hash_b}
    head = %{binding: %{run_id: "changed"}, block: block}
    current = %{binding: %{run_id: "replacement"}, block: %{number: 102, hash: @hash_a}}

    Application.put_env(
      :autolaunch,
      :lab_market_transaction_verify_result,
      {:error, {:head_changed, current}}
    )

    assert {:error, {:head_changed, ^current}} =
             LabMarketFeed.Projector.project(
               [snapshot(id, block, current_clearing_price: "2")],
               head,
               TransactionVerifier
             )

    assert {:ok, unchanged} = Autolaunch.get_public_auction(id)
    assert unchanged.current_clearing_price == "1"
  end

  test "one exact block refresh is shared and an unchanged head performs no more work" do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-one", rpc_url: "http://127.0.0.1:49713"}
    block = %{number: 100, hash: @hash_a}
    snapshot = snapshot(id, block)

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: block}},
        current_binding: {:ok, binding},
        snapshots: {:ok, [snapshot]},
        project_result: {:ok, [id]}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 1, auction_ids: [^id], block_number: 100}}

    assert %{generation: 1, head: ^block, auctions: %{@lab_address => ^snapshot}} =
             LabMarketFeed.snapshot(feed)

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).head_calls == 2 end)

    refute_receive {:autolaunch_market_updated, _update}, 50

    assert %{
             head_calls: 2,
             snapshot_calls: 2,
             snapshot_attempts: 1,
             project_calls: 1,
             verify_calls: 2
           } = FakeRuntime.state(agent)
  end

  test "cache-only changes broadcast once after a successful no-write transaction" do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-two", rpc_url: "http://127.0.0.1:49713"}
    first_block = %{number: 100, hash: @hash_a}
    second_block = %{number: 101, hash: @hash_b}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: first_block}},
        current_binding: {:ok, binding},
        snapshots: {:ok, [snapshot(id, first_block)]},
        project_result: {:ok, []}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{generation: 1, block_number: 100}}

    FakeRuntime.put(agent,
      head: {:ok, %{binding: binding, block: second_block}},
      snapshots: {:ok, [snapshot(id, second_block, currency_raised: "25")]}
    )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{generation: 2, block_number: 101}}

    assert LabMarketFeed.snapshot(feed).auctions[@lab_address].currency_raised == "25"
    assert FakeRuntime.state(agent).project_calls == 2
  end

  test "a new auction at an already accepted block is fetched exactly once" do
    first_id = Ash.UUID.generate()
    second_id = Ash.UUID.generate()
    binding = %{run_id: "run-new-auction", rpc_url: "http://127.0.0.1:49713"}
    block = %{number: 100, hash: @hash_a}
    first = snapshot(first_id, block)
    second = snapshot(second_id, block, auction_address: @other_address)

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: block}},
        current_binding: {:ok, binding},
        snapshots: {:ok, [first]},
        project_result: {:ok, [first_id]}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{auction_ids: [^first_id]}}

    FakeRuntime.put(agent,
      snapshots: {:ok, [first, second]},
      project_result: {:ok, [second_id]}
    )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{auction_ids: [^second_id]}}

    assert %{
             @lab_address => ^first,
             @other_address => ^second
           } = LabMarketFeed.snapshot(feed).auctions

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).head_calls == 3 end)

    refute_receive {:autolaunch_market_updated, _update}, 50

    assert %{snapshot_calls: 3, snapshot_attempts: 2, project_calls: 2} =
             FakeRuntime.state(agent)
  end

  test "binding drift invalidates the view and a projector failure retries its exact batch" do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-three", rpc_url: "http://127.0.0.1:49713"}
    block = %{number: 100, hash: @hash_a}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: block}},
        current_binding: {:ok, %{binding | run_id: "replacement"}},
        snapshots: {:ok, [snapshot(id, block)]},
        project_result: {:error, :late_rollback}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 1, auction_ids: [], invalidated?: true}}

    assert %{generation: 1, head: nil, degraded?: true, auctions: %{}} =
             LabMarketFeed.snapshot(feed)

    assert FakeRuntime.state(agent).project_calls == 0

    next_block = %{number: 101, hash: @hash_b}

    FakeRuntime.put(agent,
      head: {:ok, %{binding: binding, block: next_block}},
      current_binding: {:ok, binding},
      snapshots: {:ok, [snapshot(id, next_block)]},
      project_result: {:error, :late_rollback}
    )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{generation: 2, invalidated?: true}}
    wait_until(fn -> FakeRuntime.state(agent).project_calls == 1 end)

    refute_receive {:autolaunch_market_updated, _update}, 50
    assert %{generation: 2, head: nil, auctions: %{}} = LabMarketFeed.snapshot(feed)

    FakeRuntime.put(agent, project_result: {:ok, [id]})

    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 3, auction_ids: [^id], block_number: 101}}

    assert %{snapshot_calls: 2, snapshot_attempts: 2, project_calls: 2} =
             FakeRuntime.state(agent)
  end

  test "a binding change during projection invalidates once and permits one replacement refresh" do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-before-project", rpc_url: "http://127.0.0.1:49713"}
    replacement = %{binding | run_id: "run-during-project"}
    block = %{number: 100, hash: @hash_a}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: block}},
        current_binding: {:ok, binding},
        snapshots: {:ok, [snapshot(id, block)]},
        project_result: {:ok, [id]},
        binding_after_project: replacement
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).project_calls == 1 end)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 1, auction_ids: [], invalidated?: true}}

    assert %{generation: 1, head: nil, degraded?: true, auctions: %{}} =
             LabMarketFeed.snapshot(feed)

    FakeRuntime.put(agent,
      head: {:ok, %{binding: replacement, block: block}},
      current_binding: {:ok, replacement},
      binding_after_project: nil
    )

    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 2, auction_ids: [^id], block_number: 100}}

    refute_receive {:autolaunch_market_updated, %{invalidated?: true}}, 50

    assert %{generation: 2, head: ^block, degraded?: false, auctions: auctions} =
             LabMarketFeed.snapshot(feed)

    assert Map.has_key?(auctions, @lab_address)
    assert %{snapshot_calls: 2, project_calls: 2} = FakeRuntime.state(agent)
  end

  test "replacement recovery stays degraded when pre-project verification moves sideways" do
    assert_replacement_recovery_waits_for_higher_head(:pre_project, %{
      number: 100,
      hash: @hash_b
    })
  end

  test "replacement recovery stays degraded when in-transaction verification moves lower" do
    assert_replacement_recovery_waits_for_higher_head(:in_transaction, %{
      number: 99,
      hash: @hash_b
    })
  end

  test "replacement recovery stays degraded when post-project verification moves sideways" do
    assert_replacement_recovery_waits_for_higher_head(:post_project, %{
      number: 100,
      hash: @hash_b
    })
  end

  test "a projector exception is contained and enters bounded failure backoff" do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-projector-raise", rpc_url: "http://127.0.0.1:49713"}
    block = %{number: 100, hash: @hash_a}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: block}},
        current_binding: {:ok, binding},
        snapshots: {:ok, [snapshot(id, block)]},
        project_result: :raise
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).project_calls == 1 end)

    refute_receive {:autolaunch_market_updated, _update}, 50
    assert Process.alive?(feed)
    assert :sys.get_state(feed).delay == 2_000
    assert %{head: nil, auctions: %{}} = LabMarketFeed.snapshot(feed)

    FakeRuntime.put(agent, project_result: {:ok, [id]})

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{auction_ids: [^id]}}

    assert %{snapshot_calls: 1, snapshot_attempts: 1, project_calls: 2} =
             FakeRuntime.state(agent)
  end

  test "transient post-transaction verification retries the exact captured batch" do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-verify-retry", rpc_url: "http://127.0.0.1:49713"}
    block = %{number: 100, hash: @hash_a}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: block}},
        current_binding: {:ok, binding},
        snapshots: {:ok, [snapshot(id, block)]},
        project_result: {:ok, [id]},
        verify_results: [:ok, {:error, :rpc_unavailable}]
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).verify_calls == 2 end)

    refute_receive {:autolaunch_market_updated, _update}, 50
    assert :sys.get_state(feed).pending_projection.snapshots != []

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{auction_ids: [^id]}}

    assert %{snapshot_calls: 1, snapshot_attempts: 1, project_calls: 2, verify_calls: 4} =
             FakeRuntime.state(agent)
  end

  test "a direct sideways or lower head discards a transient pending projection" do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-pending-displacement", rpc_url: "http://127.0.0.1:49713"}
    accepted = %{number: 100, hash: @hash_a}
    pending = %{number: 101, hash: @hash_b}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: accepted}},
        current_binding: {:ok, binding},
        snapshots: {:ok, [snapshot(id, accepted)]},
        project_result: {:ok, [id]}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{block_number: 100}}

    FakeRuntime.put(agent,
      head: {:ok, %{binding: binding, block: pending}},
      snapshots: {:ok, [snapshot(id, pending)]},
      verify_results: [:ok, {:error, :rpc_unavailable}]
    )

    LabMarketFeed.refresh(feed)
    wait_until(fn -> :sys.get_state(feed).pending_projection != nil end)

    FakeRuntime.put(agent,
      head: {:ok, %{binding: binding, block: accepted}},
      snapshots: {:ok, []},
      verify_results: []
    )

    LabMarketFeed.refresh(feed)
    wait_until(fn -> :sys.get_state(feed).in_flight == nil end)
    assert :sys.get_state(feed).pending_projection == nil

    FakeRuntime.put(agent,
      head: {:ok, %{binding: binding, block: pending}},
      snapshots: {:ok, [snapshot(id, pending)]}
    )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{block_number: 101}}
    assert %{snapshot_calls: 4} = FakeRuntime.state(agent)
  end

  test "same-height hash changes and lower heads evict displaced cache with bounded backoff" do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-reorg", rpc_url: "http://127.0.0.1:49713"}
    accepted_block = %{number: 100, hash: @hash_a}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: accepted_block}},
        current_binding: {:ok, binding},
        snapshots: {:ok, [snapshot(id, accepted_block)]},
        project_result: {:ok, []}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{block_number: 100}}

    sideways_block = %{number: 100, hash: @hash_b}
    FakeRuntime.put(agent, head: {:ok, %{binding: binding, block: sideways_block}})
    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{generation: 2, block_hash: @hash_b}}

    assert %{generation: 2, head: ^accepted_block, degraded?: true, auctions: %{}} =
             LabMarketFeed.snapshot(feed)

    assert :sys.get_state(feed).delay == 2_000
    assert :sys.get_state(feed).attempted_addresses == MapSet.new()
    assert :sys.get_state(feed).failed_head == nil
    assert :sys.get_state(feed).pending_projection == nil

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).head_calls == 3 end)

    refute_receive {:autolaunch_market_updated, _update}, 50
    assert LabMarketFeed.snapshot(feed).generation == 2
    assert :sys.get_state(feed).delay == 4_000

    lower_block = %{number: 99, hash: @hash_b}
    FakeRuntime.put(agent, head: {:ok, %{binding: binding, block: lower_block}})
    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 3, auction_ids: [], invalidated?: true}}

    assert %{generation: 3, head: ^accepted_block, degraded?: true, auctions: %{}} =
             LabMarketFeed.snapshot(feed)

    assert :sys.get_state(feed).delay == 8_000
    assert %{snapshot_calls: 1, project_calls: 1} = FakeRuntime.state(agent)
  end

  test "an empty market broadcasts initial acceptance and recovery from a displaced head" do
    binding = %{run_id: "run-empty-recovery", rpc_url: "http://127.0.0.1:49713"}
    accepted_block = %{number: 100, hash: @hash_a}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: accepted_block}},
        current_binding: {:ok, binding},
        snapshots: {:ok, []},
        project_result: {:ok, []}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{generation: 1, auction_ids: []}}

    assert %{head: ^accepted_block, degraded?: false, auctions: %{}} =
             LabMarketFeed.snapshot(feed)

    sideways = %{number: 100, hash: @hash_b}
    FakeRuntime.put(agent, head: {:ok, %{binding: binding, block: sideways}})
    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 2, auction_ids: [], invalidated?: true}}

    assert %{head: ^accepted_block, degraded?: true, auctions: %{}} = LabMarketFeed.snapshot(feed)

    FakeRuntime.put(agent, head: {:ok, %{binding: binding, block: accepted_block}})
    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated, %{generation: 3, auction_ids: []}}

    assert %{head: ^accepted_block, degraded?: false, auctions: %{}} =
             LabMarketFeed.snapshot(feed)

    assert %{snapshot_calls: 2, project_calls: 2, verify_calls: 4} =
             FakeRuntime.state(agent)
  end

  test "a transient head failure releases the watcher for the next backoff attempt" do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-head-retry", rpc_url: "http://127.0.0.1:49713"}
    block = %{number: 100, hash: @hash_a}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:error, :rpc_unavailable},
        current_binding: {:ok, binding},
        snapshots: {:ok, [snapshot(id, block)]},
        project_result: {:ok, [id]}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).head_calls == 1 end)

    assert :sys.get_state(feed).in_flight == nil
    assert :sys.get_state(feed).delay == 2_000

    FakeRuntime.put(agent, head: {:ok, %{binding: binding, block: block}})

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{auction_ids: [^id]}}
    assert %{head_calls: 2, snapshot_calls: 1, project_calls: 1} = FakeRuntime.state(agent)
  end

  test "a replacement run clears the old cache before accepting its first block" do
    id = Ash.UUID.generate()
    binding_a = %{run_id: "run-a", rpc_url: "http://127.0.0.1:49713"}
    binding_b = %{run_id: "run-b", rpc_url: "http://127.0.0.1:49713"}
    block_a = %{number: 100, hash: @hash_a}
    block_b = %{number: 100, hash: @hash_b}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding_a, block: block_a}},
        current_binding: {:ok, binding_a},
        snapshots: {:ok, [snapshot(id, block_a, currency_raised: "10")]},
        project_result: {:ok, []}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{block_hash: @hash_a}}

    FakeRuntime.put(agent,
      head: {:ok, %{binding: binding_b, block: block_b}},
      current_binding: {:ok, binding_b},
      snapshots: {:ok, [snapshot(id, block_b, currency_raised: "20")]}
    )

    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 2, block_hash: @hash_b, invalidated?: true}}

    assert_receive {:autolaunch_market_updated,
                    %{generation: 3, block_hash: @hash_b, auction_ids: [^id]}}

    assert %{head: ^block_b, auctions: %{@lab_address => replacement}} =
             LabMarketFeed.snapshot(feed)

    assert replacement.currency_raised == "20"
    assert replacement.block_hash == @hash_b
  end

  test "a failed replacement run still emits one empty-cache invalidation" do
    binding_a = %{run_id: "run-empty-a", rpc_url: "http://127.0.0.1:49713"}
    binding_b = %{run_id: "run-empty-b", rpc_url: "http://127.0.0.1:49713"}
    block_a = %{number: 100, hash: @hash_a}
    block_b = %{number: 100, hash: @hash_b}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding_a, block: block_a}},
        current_binding: {:ok, binding_a},
        snapshots: {:ok, []},
        project_result: {:ok, []}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 1, auction_ids: [], block_hash: @hash_a}}

    FakeRuntime.put(agent,
      head: {:ok, %{binding: binding_b, block: block_b}},
      current_binding: {:ok, binding_b},
      snapshots: {:error, :rpc_unavailable, [@lab_address]}
    )

    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 2, auction_ids: [], invalidated?: true}}

    wait_until(fn -> FakeRuntime.state(agent).snapshot_calls == 2 end)
    refute_receive {:autolaunch_market_updated, _update}, 50

    assert %{generation: 2, head: nil, degraded?: true, auctions: %{}} =
             LabMarketFeed.snapshot(feed)

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).head_calls == 3 end)

    refute_receive {:autolaunch_market_updated, _update}, 50
    assert %{generation: 2, head: nil, degraded?: true} = LabMarketFeed.snapshot(feed)
    assert FakeRuntime.state(agent).snapshot_calls == 2
  end

  test "an exact-block read failure is memoized while head checks continue" do
    binding = %{run_id: "run-failed", rpc_url: "http://127.0.0.1:49713"}
    block = %{number: 100, hash: @hash_a}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: block}},
        current_binding: {:ok, binding},
        snapshots: {:error, :rpc_failed, [@lab_address]},
        project_result: {:ok, []}
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).snapshot_calls == 1 end)

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).head_calls == 2 end)

    assert %{head_calls: 2, snapshot_calls: 2, snapshot_attempts: 1, project_calls: 0} =
             FakeRuntime.state(agent)

    assert %{head: nil, auctions: %{}} = LabMarketFeed.snapshot(feed)
  end

  test "the real reader refuses a 257th exact lab auction before any RPC snapshot work" do
    actor = %SystemActor{}

    Autolaunch.TestSupport.project_auction(
      title: "Interleaved non-lab row",
      featured: false,
      state: :active
    )
    |> Autolaunch.set_auction_bid_terms!(@other_address, @other_address, "REGENT", 18, "1",
      actor: actor
    )

    creator_id = Autolaunch.TestSupport.register_creator!().id

    inputs =
      Enum.map(1..257, fn number ->
        address = "0x" <> (number |> Integer.to_string(16) |> String.pad_leading(40, "0"))

        %{
          projection_id: LabProjection.auction_id(address),
          title: "Capacity #{number}",
          featured: false,
          state: :active,
          auction_address: address,
          creator_human_account_id: creator_id
        }
      end)

    Ash.bulk_create!(inputs, Auction, :project_lab,
      actor: actor,
      domain: Autolaunch,
      return_errors?: true,
      stop_on_error?: true
    )

    assert {:error, :market_capacity_exceeded} =
             LabMarketFeed.Reader.snapshots(%{}, 256, MapSet.new())
  end

  defp snapshot(id, block, overrides \\ []) do
    Map.merge(
      %{
        auction_id: id,
        auction_address: @lab_address,
        state: :active,
        current_clearing_price: "2",
        block_number: block.number,
        block_hash: block.hash,
        start_block: 90,
        end_block: 200,
        claim_block: 220,
        currency_raised: "10",
        remaining_supply: "1000",
        graduated?: false,
        pool_id: nil
      },
      Map.new(overrides)
    )
  end

  defp assert_replacement_recovery_waits_for_higher_head(stage, displaced_block) do
    id = Ash.UUID.generate()
    binding = %{run_id: "run-before-replacement", rpc_url: "http://127.0.0.1:49713"}
    replacement = %{binding | run_id: "run-replacement"}
    recovery_block = %{number: 100, hash: @hash_a}
    displaced = %{binding: replacement, block: displaced_block}

    {:ok, agent} =
      FakeRuntime.install(%{
        head: {:ok, %{binding: binding, block: recovery_block}},
        current_binding: {:ok, binding},
        snapshots: {:ok, [snapshot(id, recovery_block)]},
        project_result: {:ok, [id]},
        binding_after_project: replacement
      })

    Application.put_env(:autolaunch, :lab_market_feed_test_agent, agent)
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

    {:ok, feed} =
      start_supervised(
        {LabMarketFeed, name: nil, reader: FakeReader, projector: FakeProjector, poll?: false}
      )

    LabMarketFeed.refresh(feed)
    assert_receive {:autolaunch_market_updated, %{generation: 1, invalidated?: true}}

    recovery_options =
      case stage do
        :pre_project -> [verify_results: [{:error, {:head_changed, displaced}}]]
        :in_transaction -> [project_result: {:error, {:head_changed, displaced}}]
        :post_project -> [verify_results: [:ok, {:error, {:head_changed, displaced}}]]
      end

    FakeRuntime.put(
      agent,
      Keyword.merge(
        [
          head: {:ok, %{binding: replacement, block: recovery_block}},
          current_binding: {:ok, replacement},
          binding_after_project: nil,
          project_result: {:ok, [id]}
        ],
        recovery_options
      )
    )

    LabMarketFeed.refresh(feed)
    wait_until(fn -> :sys.get_state(feed).in_flight == nil end)

    refute_receive {:autolaunch_market_updated, _update}, 50

    assert %{generation: 1, head: nil, degraded?: true, auctions: %{}} =
             LabMarketFeed.snapshot(feed)

    attempts_after_displacement = FakeRuntime.state(agent).snapshot_calls

    FakeRuntime.put(agent,
      head: {:ok, displaced},
      current_binding: {:ok, replacement},
      verify_results: [],
      project_result: {:ok, [id]}
    )

    LabMarketFeed.refresh(feed)
    wait_until(fn -> FakeRuntime.state(agent).head_calls >= 3 end)

    refute_receive {:autolaunch_market_updated, _update}, 50
    assert FakeRuntime.state(agent).snapshot_calls == attempts_after_displacement

    assert %{generation: 1, head: nil, degraded?: true, auctions: %{}} =
             LabMarketFeed.snapshot(feed)

    higher_block = %{number: 101, hash: @hash_b}

    FakeRuntime.put(agent,
      head: {:ok, %{binding: replacement, block: higher_block}},
      snapshots: {:ok, [snapshot(id, higher_block)]}
    )

    LabMarketFeed.refresh(feed)

    assert_receive {:autolaunch_market_updated,
                    %{generation: 2, auction_ids: [^id], block_number: 101}}

    assert %{generation: 2, head: ^higher_block, degraded?: false} =
             LabMarketFeed.snapshot(feed)
  end

  defp wait_until(callback, attempts \\ 50)

  defp wait_until(callback, attempts) when attempts > 0 do
    if callback.() do
      :ok
    else
      Process.sleep(10)
      wait_until(callback, attempts - 1)
    end
  end

  defp wait_until(_callback, 0), do: flunk("condition did not become true")
end
