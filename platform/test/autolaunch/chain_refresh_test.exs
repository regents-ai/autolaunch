defmodule Autolaunch.ChainRefreshTest do
  use Autolaunch.IndexerCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo

  alias Autolaunch.{AuctionActivity, ChainRefresh}
  alias Autolaunch.Indexer.ReadChain

  @source "0x" <> String.duplicate("ab", 20)

  # The site starts its jobs only once launches open; a press queues or moves
  # jobs here, and no queue runs under ExUnit.
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

  # A landed press asks the chain's ledger to read again: its waiting job moves
  # from five minutes away to the end of the ten-second gap.
  test "a refresh brings the ledger's five-minute read forward" do
    open_launches()
    Oban.insert!(ReadChain.new(%{chain_id: chain_id()}, schedule_in: 300))

    :ok = ChainRefresh.request(chain_id() + 1)
    assert seconds_until(ReadChain, %{chain_id: chain_id()}) > 290

    :ok = ChainRefresh.request(chain_id())
    assert seconds_until(ReadChain, %{chain_id: chain_id()}) <= ChainRefresh.gap_s()
  end

  # A landed press brings each listed auction's next activity read on that
  # chain forward from five minutes away to the end of the ten-second gap. A
  # read already due sooner keeps its time, so presses that keep coming never
  # put it off.
  test "a refresh brings an auction's next activity read forward, never back" do
    open_launches()
    waiting = Autolaunch.TestSupport.project_auction(chain_id: chain_id(), state: :active)
    due = Autolaunch.TestSupport.project_auction(chain_id: chain_id(), state: :active)
    Oban.insert!(AuctionActivity.new(%{auction_id: waiting.id}, schedule_in: 300))
    Oban.insert!(AuctionActivity.new(%{auction_id: due.id}, schedule_in: 2))

    :ok = ChainRefresh.request(chain_id() + 1)
    assert seconds_until(AuctionActivity, %{auction_id: waiting.id}) > 290

    :ok = ChainRefresh.request(chain_id())
    assert seconds_until(AuctionActivity, %{auction_id: waiting.id}) <= ChainRefresh.gap_s()
    assert seconds_until(AuctionActivity, %{auction_id: due.id}) <= 2
  end

  # Once launches are open, a creator's Memestock launch press runs discovery at
  # once, so the launch is listed without waiting for the five-minute schedule.
  test "a refresh on a chain with a Memestock launchpad runs its discovery at once" do
    :ok = ChainRefresh.request(chain_id())
    refute_enqueued(worker: Autolaunch.LaunchDiscovery.Workers.DiscoverMemestock)

    open_launches()

    :ok = ChainRefresh.request(chain_id() + 1)
    refute_enqueued(worker: Autolaunch.LaunchDiscovery.Workers.DiscoverMemestock)

    :ok = ChainRefresh.request(chain_id())
    assert_enqueued(worker: Autolaunch.LaunchDiscovery.Workers.DiscoverMemestock)
  end

  defp open_launches do
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
  end

  defp seconds_until(worker, args) do
    [job] = all_enqueued(worker: worker, args: args)
    DateTime.diff(job.scheduled_at, DateTime.utc_now())
  end
end
