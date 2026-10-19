defmodule AutolaunchWeb.ShareVideoQueueTest do
  @moduledoc """
  Share videos are asked for by many people at once, and by one person in
  several tabs at once. The site still makes at most 1000 videos in a day,
  each video is queued once however many ask for it together, and a person's
  made video is kept and served until three hours have passed.

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

  @daily 1000

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
    # The site has room for zero to four more videos today. One to ten asks
    # are released together, each by one of six people for their own video,
    # or for the launch's own video. Each run has a launch of its own; only
    # the launch's id names its videos, so it needs no stored launch. The
    # day's videos are filled once, all but four, and each run fills its own
    # share of the rest.
    filled = %Autolaunch.Auction{id: Ash.UUID.generate()}
    made_but(filled, 4)
    on_exit(fn -> forget(filled) end)

    check all(
            room <- integer(0..4),
            asks <-
              list_of(one_of([integer(0..5), constant(:launch)]), min_length: 1, max_length: 10),
            max_runs: 100
          ) do
      auction = %Autolaunch.Auction{id: Ash.UUID.generate()}
      people = 1_000_000_000 + :rand.uniform(1_000_000_000)
      wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

      try do
        made_but(auction, room)

        answers =
          asks
          |> Enum.map(fn
            :launch ->
              {:launch, fn -> ShareVideo.fetch(auction, :auction, nil, nil, now) end}

            person ->
              {person,
               fn -> ShareVideo.fetch(auction, :auction, wallet, people + person, now) end}
          end)
          |> at_once()

        assert Enum.all?(answers, fn {_asker, answer} ->
                 match?({:waiting, _}, answer) or answer == {:error, :daily_limit}
               end)

        # A launch's own video is always made.
        assert answers
               |> Enum.filter(&match?({:launch, _}, &1))
               |> Enum.all?(&match?({_launch, {:waiting, _}}, &1))

        # As many people's videos as there was room for, when that many asked,
        # less the launch's own when it took the room first: the cap refuses
        # nothing it should let through. A person's tabs all get the same
        # answer.
        {own, launch} = auction |> requests() |> Enum.split_with(& &1.human_account_id)
        asked = asks |> Enum.reject(&(&1 == :launch)) |> Enum.uniq()

        least = min(length(asked), max(room - length(launch), 0))
        assert length(own) in least..min(length(asked), room)

        for person <- asked do
          theirs = for {^person, answer} <- answers, uniq: true, do: elem(answer, 0)
          made? = Enum.any?(own, &(&1.human_account_id == people + person))
          assert theirs == if(made?, do: [:waiting], else: [:error])
        end

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

  test "a person's video is kept until three hours have passed, then made again", %{now: now} do
    auction = %Autolaunch.Auction{id: Ash.UUID.generate()}
    person = 1_000_000_000 + :rand.uniform(1_000_000_000)
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    ask = fn who, at -> unboxed(fn -> ShareVideo.fetch(auction, :token, wallet, who, at) end) end
    later = DateTime.add(now, 3 * 3600 + 1)

    try do
      saved(auction, person, wallet, "first video", now)

      # Served as made, without asking for a new one, for three hours.
      assert ask.(person, DateTime.add(now, 2 * 3600)) == {:ok, "first video"}
      assert [_saved] = requests(auction)

      # After that, asking makes a new one, and the old one stays stored.
      assert {:waiting, _ahead} = ask.(person, later)
      assert auction |> requests() |> Enum.map(& &1.state) |> Enum.sort() == [:queued, :ready]

      # Once the site has made all of the day's videos, a video already queued
      # is still answered with its place in line, a person with a video saved
      # keeps it, and one with none is told so.
      made_but(auction, 0)
      assert ask.(person, later) == {:waiting, 0}
      forget_queued(auction)
      made_but(auction, 0)
      assert ask.(person, later) == {:ok, "first video"}
      assert ask.(person + 1, now) == {:error, :daily_limit}
    after
      forget(auction)
    end
  end

  test "a video is deleted once it is a day old", %{now: now} do
    auction = %Autolaunch.Auction{id: Ash.UUID.generate()}
    person = 1_000_000_000 + :rand.uniform(1_000_000_000)
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    try do
      saved(auction, person, wallet, "day-old video", DateTime.add(now, -25 * 3600))
      saved(auction, person + 1, wallet, "fresh video", DateTime.add(now, -23 * 3600))

      # A day-old video is never served, even once the site has made all of
      # the day's videos, when a saved one would be.
      made_but(auction, 0)

      assert unboxed(fn -> ShareVideo.fetch(auction, :token, wallet, person, now) end) ==
               {:error, :daily_limit}

      # The hourly sweep deletes it and keeps the younger one.
      unboxed(fn ->
        AshOban.Test.schedule_and_run_triggers({ShareVideoRequest, :forget}, actor: %System{})
      end)

      assert auction |> requests() |> Enum.map(& &1.human_account_id) == [person + 1]
    after
      forget(auction)
    end
  end

  test "past their space, the oldest made videos are deleted first", %{now: now} do
    auction = %Autolaunch.Auction{id: Ash.UUID.generate()}
    person = 1_000_000_000 + :rand.uniform(1_000_000_000)
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    video = String.duplicate("v", 400)

    try do
      for {who, hours_ago} <- [{person, 3}, {person + 1, 2}, {person + 2, 1}],
          do: saved(auction, who, wallet, video, DateTime.add(now, -hours_ago * 3600))

      ask = fn ->
        unboxed(fn -> ShareVideo.fetch(auction, :token, wallet, person + 3, now) end)
      end

      assert {:waiting, _ahead} = ask.()

      :ok = unboxed(fn -> Autolaunch.keep_share_videos_under!(1000, actor: %System{}) end)

      # Two of the three 400-byte videos fit in 1000 bytes: the oldest goes,
      # and the queued request, which holds no video, stays.
      left = auction |> requests() |> Enum.map(&{&1.human_account_id, &1.state}) |> Enum.sort()
      assert left == [{person + 1, :ready}, {person + 2, :ready}, {person + 3, :queued}]
    after
      forget(auction)
    end
  end

  # Fills the day's videos, all but `room`, with launch videos of `auction`'s.
  defp made_but(auction, room) do
    made =
      unboxed(fn ->
        ShareVideoRequest
        |> Ash.Query.for_read(:made_today, %{}, actor: %System{})
        |> Ash.count!(actor: %System{})
      end)

    rows =
      for n <- 1..(@daily - room - made)//1,
          do: row(auction, %{key: "#{auction.id}:filler:#{n}", state: "ready"})

    unboxed(fn -> Repo.insert_all("share_video_requests", rows) end)
  end

  # A person's made video, stored at `at`.
  defp saved(auction, person, wallet, mp4, at) do
    unboxed(fn ->
      Repo.insert_all("share_video_requests", [
        row(auction, %{
          key: "#{auction.id}:token:account:#{person}",
          kind: "token",
          human_account_id: person,
          wallet: wallet,
          state: "ready",
          mp4: mp4,
          inserted_at: at,
          updated_at: at
        })
      ])
    end)
  end

  defp row(auction, fields) do
    Map.merge(
      %{id: Ecto.UUID.bingenerate(), kind: "auction", auction_id: Ecto.UUID.dump!(auction.id)},
      fields
    )
  end

  # Every call waits in its own process until all are started, then all go.
  defp at_once(calls) do
    tasks =
      Enum.map(calls, fn {asker, call} ->
        Task.async(fn ->
          receive do
            :go -> {asker, unboxed(call)}
          end
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 30_000)
  end

  # Nothing a run writes outlives it: its requests, their queued renders and
  # its filler.
  defp forget(auction),
    do:
      drop(auction |> requests(), Ash.Query.filter(ShareVideoRequest, auction_id == ^auction.id))

  # The run's queued requests and their queued renders.
  defp forget_queued(auction) do
    queued = auction |> requests() |> Enum.filter(&(&1.state == :queued))
    ids = Enum.map(queued, & &1.id)
    drop(queued, Ash.Query.filter(ShareVideoRequest, id in ^ids))
  end

  # Drops `rows`, and the queued renders of `requests` with them. Oban's jobs
  # are not an Ash resource, so the renders go straight through the repo.
  defp drop(requests, rows) do
    ids = Enum.map(requests, & &1.id)

    unboxed(fn ->
      Repo.delete_all(
        where(Oban.Job, [job], fragment("?->'primary_key'->>'id'", job.args) in ^ids)
      )

      Ash.bulk_destroy!(rows, :destroy, %{}, actor: %System{}, strategy: :stream)
    end)
  end

  # A run's own requests, without the day's filler.
  defp requests(auction) do
    unboxed(fn ->
      ShareVideoRequest
      |> Ash.Query.filter(auction_id == ^auction.id and not contains(key, ":filler:"))
      |> Ash.read!(actor: %System{})
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
