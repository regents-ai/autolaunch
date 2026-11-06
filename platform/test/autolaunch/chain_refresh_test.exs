defmodule Autolaunch.ChainRefreshTest do
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo

  alias Autolaunch.{AuctionActivity, ChainRefresh}

  @chain_id 8453

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

  # Once launches are open, a creator's Revstake or Memestock launch press runs
  # discovery at once, so the launch is listed without waiting for the
  # five-minute schedule.
  test "a refresh on a chain with a Base launchpad runs its discovery at once" do
    :ok = ChainRefresh.request(chain_id())
    refute_enqueued(worker: Autolaunch.LaunchDiscovery.Workers.Discover)

    open_launches()

    :ok = ChainRefresh.request(chain_id() + 1)
    refute_enqueued(worker: Autolaunch.LaunchDiscovery.Workers.Discover)

    :ok = ChainRefresh.request(chain_id())
    assert_enqueued(worker: Autolaunch.LaunchDiscovery.Workers.Discover)
  end

  defp open_launches do
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
  end

  defp chain_id, do: @chain_id

  defp seconds_until(worker, args) do
    [job] = all_enqueued(worker: worker, args: args)
    DateTime.diff(job.scheduled_at, DateTime.utc_now())
  end
end
