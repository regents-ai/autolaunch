defmodule AutolaunchWeb.ShareVideoLimitTest do
  @moduledoc """
  A share video's address is held to the same number of requests a minute as
  the API and the share pictures, so one address cannot keep the video queue
  busy: past it the answer is 429 and no video is asked for.

  The requests come from an address of their own, so the budget they spend is
  no other case's.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport
  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  @budget 120

  setup do
    # The site starts its jobs only once launches open. A request queues its
    # render here; no queue runs under ExUnit, so none is made.
    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    :ok
  end

  test "a video address answers 429 once its address has spent the minute's requests",
       %{conn: conn} do
    stored = TestSupport.project_auction(chain_id: 8453, symbol: "LIMIT", state: :active)
    {:ok, auction} = Paths.find_auction("LIMIT", String.slice(stored.auction_address, -5, 5))
    path = URI.parse(Paths.auction_video_url(auction, "1")).path
    conn = %{conn | remote_ip: {203, 0, 113, 7}}

    statuses = for _request <- 1..(@budget + 1), do: get(conn, path).status

    assert Enum.take(statuses, @budget) == List.duplicate(202, @budget)
    assert List.last(statuses) == 429
  end
end
