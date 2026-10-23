defmodule Autolaunch.ChainRefreshTest do
  use Autolaunch.IndexerCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo

  alias Autolaunch.ChainRefresh
  alias Autolaunch.DurableWork.Runner
  alias Autolaunch.Indexer.Handler

  @source "0x" <> String.duplicate("ab", 20)

  # The site starts its jobs only once launches open; a press queues Memestock
  # discovery here, and no queue runs under ExUnit.
  setup do
    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    :ok
  end

  # The ledger wakes every five minutes and reads at most a few blocks a pass,
  # so a wake that stopped after one pass would fall further behind Base with
  # every wake. One wake keeps passing until it reaches the safe head.
  test "one wake reads the ledger up to the safe head, however far behind it is" do
    start_endpoint(chain(blocks(100..130)))
    admit(@source, 100)

    assert {:ok, _committed} = pass()
    assert cursor().next_block_to_fetch == 131
  end

  # A landed press asks the chain's ledger to read again: its runner's next
  # poll moves from five minutes away to the end of the ten-second gap.
  test "a refresh brings the ledger's five-minute poll forward" do
    {:ok, queue} = Agent.start_link(fn -> [] end)
    {:ok, active} = Agent.start_link(fn -> %{current: 0, maximum: 0} end)

    runner =
      start_supervised!(
        {Runner,
         handler: Autolaunch.TestDurableWorkHandler,
         context: %{owner: self(), queue: queue, active: active},
         poll_interval_ms: 300_000,
         refresh_topic: Handler.topic(chain_id())}
      )

    assert_receive {:durable_poll, _handler, 1, _at}
    assert next_poll_ms(runner) > 290_000

    :ok = ChainRefresh.request(chain_id() + 1)
    assert next_poll_ms(runner) > 290_000

    :ok = ChainRefresh.request(chain_id())
    assert next_poll_ms(runner) <= ChainRefresh.gap_s() * 1_000
  end

  # A landed press brings each listed auction's next activity read on that
  # chain forward from five minutes away to the end of the ten-second gap.
  test "a refresh brings an auction's next activity read forward" do
    auction = Autolaunch.TestSupport.project_auction(chain_id: chain_id(), state: :active)
    later = DateTime.add(DateTime.utc_now(), 300)

    auction
    |> Ash.Changeset.for_update(:schedule_activity, %{activity_due_at: later}, actor: actor())
    |> Ash.update!()

    :ok = ChainRefresh.request(chain_id() + 1)
    assert DateTime.diff(due(auction), DateTime.utc_now()) > 290

    :ok = ChainRefresh.request(chain_id())
    assert DateTime.diff(due(auction), DateTime.utc_now()) <= ChainRefresh.gap_s()
  end

  # Once launches are open, a creator's Memestock launch press runs discovery at
  # once, so the launch is listed without waiting for the five-minute schedule.
  test "a refresh on a chain with a Memestock launchpad runs its discovery at once" do
    :ok = ChainRefresh.request(chain_id())
    refute_enqueued(worker: Autolaunch.LaunchDiscovery.Workers.DiscoverMemestock)

    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)

    :ok = ChainRefresh.request(chain_id() + 1)
    refute_enqueued(worker: Autolaunch.LaunchDiscovery.Workers.DiscoverMemestock)

    :ok = ChainRefresh.request(chain_id())
    assert_enqueued(worker: Autolaunch.LaunchDiscovery.Workers.DiscoverMemestock)
  end

  defp due(auction),
    do: Ash.get!(Autolaunch.Auction, auction.id, actor: actor()).activity_due_at

  defp next_poll_ms(runner), do: Process.read_timer(:sys.get_state(runner).timer_ref)
end
