defmodule AutolaunchWeb.ShareVideoQueueTest do
  @moduledoc """
  Share videos are asked for by many people at once, and by one account in
  several tabs at once. An account still makes at most three videos of its own
  in a day, and each video is queued once however many ask for it together.

  Each ask runs in its own process outside the sandbox
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), so it writes and commits in its
  own transaction on its own connection, as requests do on the site, and gives
  the connection back when it is done. Nothing is shared between them but the
  database.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Ecto.Query, only: [where: 3]
  require Ash.Query

  alias Autolaunch.Actors.System
  alias Autolaunch.Repo
  alias Autolaunch.ShareVideoRequest
  alias AutolaunchWeb.ShareVideo

  @moduletag :capture_log

  setup do
    # The site starts its jobs only once launches open. Each request queues
    # its render here; no queue runs under ExUnit, so none is made.
    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    %{now: DateTime.utc_now()}
  end

  property "share video cap holds under concurrent requests", %{now: now} do
    # One to ten asks released together by a new account, each for one of six
    # videos of its own (one for each of six quarter hours) or for the
    # launch's own video. Each run has a launch of its own; only the launch's
    # id names its videos, so it needs no stored launch.
    check all(
            videos <-
              list_of(one_of([integer(0..5), constant(:launch)]), min_length: 1, max_length: 10),
            max_runs: 300
          ) do
      auction = %Autolaunch.Auction{id: Ash.UUID.generate()}
      account = 1_000_000_000 + :rand.uniform(1_000_000_000)
      wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

      try do
        answers =
          videos
          |> Enum.map(fn
            :launch ->
              fn -> ShareVideo.fetch(auction, :auction, nil, nil, now) end

            video ->
              fn -> ShareVideo.fetch(auction, :auction, wallet, account, at(now, video)) end
          end)
          |> at_once()

        assert Enum.all?(answers, &(match?({:waiting, _}, &1) or &1 == {:error, :daily_limit}))

        # At most three videos of its own in the day, and three when it asked
        # for three or more: the cap refuses nothing it should let through.
        made = unboxed(fn -> Autolaunch.share_videos_made_today!(account, actor: %System{}) end)
        own = videos |> Enum.reject(&(&1 == :launch)) |> Enum.uniq() |> length()
        assert made |> Enum.map(& &1.key) |> Enum.uniq() |> length() == min(own, 3)

        # Every video is queued at most once, whoever asked for it and how often.
        assert auction
               |> requests()
               |> Enum.filter(&(&1.state == :queued))
               |> Enum.frequencies_by(& &1.key)
               |> Enum.all?(fn {_key, queued} -> queued == 1 end)
      after
        forget(auction)
      end
    end
  end

  defp at(now, quarter_hour), do: DateTime.add(now, quarter_hour * 900)

  # Every call waits in its own process until all are started, then all go.
  defp at_once(calls) do
    tasks =
      Enum.map(calls, fn call ->
        Task.async(fn ->
          receive do
            :go -> unboxed(call)
          end
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 30_000)
  end

  # Nothing a run writes outlives it: its requests and their queued renders.
  defp forget(auction) do
    ids = Enum.map(requests(auction), & &1.id)

    unboxed(fn ->
      Repo.delete_all(
        where(Oban.Job, [job], fragment("?->'primary_key'->>'id'", job.args) in ^ids)
      )

      ShareVideoRequest
      |> Ash.Query.filter(auction_id == ^auction.id)
      |> Ash.bulk_destroy!(:destroy, %{}, actor: %System{}, strategy: :stream)
    end)
  end

  defp requests(auction) do
    unboxed(fn ->
      ShareVideoRequest
      |> Ash.Query.filter(auction_id == ^auction.id)
      |> Ash.read!(actor: %System{})
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
