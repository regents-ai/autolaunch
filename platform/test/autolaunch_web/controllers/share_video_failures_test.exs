defmodule AutolaunchWeb.ShareVideoFailuresTest do
  @moduledoc """
  The site's try-again page (503) means one thing: the database could not be
  reached. Every other reason a share video cannot be had answers with its own
  status and a plain line the share window shows.

  A lost connection is made by cutting the case's own database connection
  (`pg_terminate_backend`, from a second connection) at a chosen point in the
  request, as it would be if the database went away just then.
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
    # Cut once the request has read the video's queue: its write loses the
    # connection.
    cut_when([:autolaunch, :repo, :query], &(&1.source == "share_video_requests"))

    {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
    assert body =~ "Try again"
  end

  test "a connection lost before the request reads the video's queue is the try-again page",
       %{conn: conn, path: path} do
    # Cut as the read of the video's queue starts, after the launch was found.
    cut_when([:ash, :autolaunch, :read, :start], &(&1.resource == ShareVideoRequest))

    {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
    assert body =~ "Try again"
  end

  test "a connection lost while counting a queued video's place in line is the try-again page",
       %{conn: conn, path: path} do
    assert get(conn, path).status == 202

    # The video is queued now. Asking again reads its request, then counts the
    # requests ahead of it; cut between the two.
    cut_when([:autolaunch, :repo, :query], &(&1.source == "share_video_requests"))

    {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
    assert body =~ "Try again"
  end

  test "a database error that is not a lost connection answers with its own line",
       %{conn: conn, path: path} do
    # Lasts only as long as this case's sandboxed transaction: the read of the
    # video's queue fails with 42P01 (undefined_table), not a lost connection.
    Repo.query!(
      "ALTER TABLE autolaunch_app.share_video_requests RENAME TO share_video_requests_unreadable"
    )

    failed = get(conn, path)

    assert json_response(failed, 500) == %{
             "error" => "failed",
             "message" => "Your video couldn't be asked for just now. Try again in a moment."
           }
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

  # Cuts this case's database connection the first time `event` fires in this
  # process with metadata `cut?` accepts.
  defp cut_when(event, cut?) do
    test = self()
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

    cutter =
      start_supervised!(
        {Postgrex,
         Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])}
      )

    handler = "cut-#{inspect(test)}"

    :telemetry.attach(
      handler,
      event,
      fn _event, _measurements, metadata, _config ->
        if self() == test and cut?.(metadata) do
          :telemetry.detach(handler)
          Postgrex.query!(cutter, "SELECT pg_terminate_backend($1)", [backend])
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
