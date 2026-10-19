defmodule AutolaunchWeb.ShareVideoFailuresTest do
  @moduledoc """
  The site's try-again page (503) means one thing: the database could not be
  reached. Every other reason a share video cannot be had answers with its own
  status and a plain line the share window shows.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.{Repo, ShareVideoRequest, TestSupport}
  alias AutolaunchWeb.Paths

  require Ash.Query

  @moduletag :capture_log

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

    stored = TestSupport.project_auction(chain_id: 8453, symbol: "FAILS")
    {:ok, auction} = Paths.find_auction("FAILS", String.slice(stored.auction_address, -5, 5))
    %{auction: auction, path: URI.parse(Paths.auction_video_url(auction, "1")).path}
  end

  test "SHARE_VIDEO_OUTAGE_ONLY_FOR_A_LOST_CONNECTION: a lost database connection is the try-again page",
       %{conn: conn, path: path} do
    # The case's own database connection is cut from a second connection the
    # moment the request has read the video's queue, so the request loses its
    # connection part-way, as it would if the database went away.
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

    cutter =
      start_supervised!(
        {Postgrex,
         Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])}
      )

    cut_after_queue_read(self(), cutter, backend)

    {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
    assert body =~ "Try again"
  end

  test "a video that couldn't be made answers with its own line, not the try-again page",
       %{conn: conn, auction: auction, path: path} do
    asked = get(conn, path)
    assert asked.status == 202

    # The render failed, as the render job marks it when a video cannot be made.
    [request] =
      ShareVideoRequest
      |> Ash.Query.filter(auction_id == ^auction.id)
      |> Ash.read!(actor: %System{})

    Ash.update!(request, %{}, action: :fail, actor: %System{})

    failed = get(conn, path)
    assert failed.status == 500

    assert json_response(failed, 500) == %{
             "error" => "render_failed",
             "message" => "Your video couldn't be made. Try again in a moment."
           }
  end

  defp cut_after_queue_read(test, cutter, backend) do
    handler = "cut-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:autolaunch, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test and metadata.source == "share_video_requests" do
          :telemetry.detach(handler)
          Postgrex.query!(cutter, "SELECT pg_terminate_backend($1)", [backend])
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
