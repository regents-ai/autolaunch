defmodule AutolaunchWeb.ShareVideoFailuresTest do
  @moduledoc """
  The site's try-again page (503) means one thing: the database could not be
  reached. Every other reason a share video cannot be had answers with its own
  status and a plain line the share window shows.

  A lost connection is made by cutting the case's own database connection
  (`pg_terminate_backend`, from a second connection) at a chosen point in the
  request, as it would be if the database went away just then. Other database
  errors are made by the database itself: a trigger, created inside the case's
  own transaction, that refuses the request's write with a chosen code.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.{Repo, ShareVideoRequest, TestSupport}
  alias AutolaunchWeb.Paths

  import ExUnit.CaptureLog

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

    {failed, log} = with_log(fn -> get(conn, path) end)

    assert json_response(failed, 500) == %{
             "error" => "failed",
             "message" => "Your video couldn't be asked for just now. Try again in a moment."
           }

    # The log names what failed, as Ash hands it over, and carries none of
    # the database's message, which can hold the request's own values.
    assert log =~ "share video request failed: Ash.Error.Unknown.UnknownError"
    refute log =~ "share_video_requests"
    refute log =~ "42P01"
  end

  test "every lost-connection code the database reports answers the try-again page",
       %{conn: conn, path: path} do
    # The connection exceptions (class 08) and the server shutting down or
    # starting (57P01 to 57P03), each raised by the database on the write.
    for code <- ~w(08000 08001 08003 08004 08006 08007 08P01 57P01 57P02 57P03) do
      refuse_writes(code, "refused")

      {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
      assert body =~ "Try again", "#{code} did not answer the try-again page"
    end
  end

  test "a database code next to a lost connection's answers with its own line",
       %{conn: conn, path: path} do
    # Codes beside the lost-connection ones, and a message dressed as one.
    for {code, message} <- [
          {"57P04", "refused"},
          {"57P05", "refused"},
          {"57014", "refused"},
          {"0A000", "refused"},
          {"P0001", "** (Postgrex.Error) FATAL 57P01 (admin_shutdown) terminating connection"}
        ] do
      refuse_writes(code, message)

      failed = get(conn, path)
      assert failed.status == 500, "#{code} answered #{failed.status}"
      assert json_response(failed, 500)["error"] == "failed"
    end
  end

  test "a connection that waits too long for the database is the try-again page",
       %{conn: conn, path: path} do
    # Held as the request starts reading the video's queue: Ash hands over the
    # connection's error as text.
    holder = hold_when([:ash, :autolaunch, :read, :start], &(&1.resource == ShareVideoRequest))

    {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
    assert body =~ "Try again"
    Task.await(holder.(), 10_000)
  end

  test "a connection that waits too long to count a queued video's place in line is the try-again page",
       %{conn: conn, path: path} do
    assert get(conn, path).status == 202

    # Held once the second ask has read its queued request: the count of the
    # requests ahead of it raises the connection's own error, unwrapped.
    holder = hold_when([:autolaunch, :repo, :query], &(&1.source == "share_video_requests"))

    {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
    assert body =~ "Try again"
    Task.await(holder.(), 10_000)
  end

  test "no word of a database error's message reaches the log", %{conn: conn, path: path} do
    refuse_writes("P0001", "alice 0xab1")
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    # A handler on the failed write's query event fails too, so telemetry's own
    # error line, written as it detaches the handler, is part of what is read.
    test = self()
    handler = "failing-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:autolaunch, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test and match?({:error, _}, metadata.result), do: raise("handler failed")
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {failed, log} = with_log([level: :debug], fn -> get(conn, path) end)
    Logger.configure(level: level)

    assert json_response(failed, 500)["error"] == "failed"
    # Every level is captured: the database layer's own query lines and
    # telemetry's line for the handler it detached.
    assert log =~ "QUERY ERROR"
    assert log =~ "has failed and has been detached"
    refute log =~ "alice"
    refute log =~ "0xab1"
    assert log =~ "share video request failed: Ash.Error.Unknown.UnknownError"
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

  # The first time `event` fires in this process with metadata `hold?`
  # accepts, another caller holds the case's one connection for four seconds,
  # so the request's next query is dropped from the queue after two
  # (`queue_target` in config/test.exs) with the connection's own error,
  # `DBConnection.ConnectionError`. Returns a function giving the holder's task.
  defp hold_when(event, hold?) do
    test = self()
    handler = "hold-#{inspect(test)}"

    :telemetry.attach(
      handler,
      event,
      fn _event, _measurements, metadata, _config ->
        if self() == test and hold?.(metadata), do: hold(handler)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    fn -> Process.get(:holder) end
  end

  defp hold(handler) do
    :telemetry.detach(handler)
    Process.put(:holder, Task.async(fn -> Repo.query!("SELECT pg_sleep(4)") end))
    Process.sleep(200)
  end

  # From now on, until the case ends, the database refuses every write of a
  # share-video request with `code` and `message`.
  defp refuse_writes(code, message) do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION autolaunch_app.share_video_requests_refused() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '#{message}' USING ERRCODE = '#{code}';
    END
    $$
    """)

    Repo.query!(
      "CREATE OR REPLACE TRIGGER share_video_requests_refused BEFORE INSERT ON autolaunch_app.share_video_requests FOR EACH ROW EXECUTE FUNCTION autolaunch_app.share_video_requests_refused()"
    )
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
