defmodule AutolaunchWeb.ShareVideoRenderTest do
  @moduledoc """
  A share video made while the saved videos hold less than the site's saved
  space is saved; one made at or past it is still made and handed over once,
  but not saved.

  The render runs for real, from a request asked for through
  `AutolaunchWeb.ShareVideo.fetch/5` and its queued job, on a stored running
  auction. Only three things stand in: the auction's chain is a node started
  here that answers the two reads its story makes, `ffmpeg` is a script that
  takes every frame and writes a fixed small MP4, and the saved space is set
  small for this case.
  """
  use Autolaunch.DataCase, async: false

  alias Autolaunch.TestSupport
  alias AutolaunchWeb.ShareVideo

  @moduletag :capture_log

  # The stand-in ffmpeg's video: an MP4's opening box.
  @mp4 <<0, 0, 0, 24, "ftypmp42", 0, 0, 0, 0, "mp42isom">>

  defmodule Node do
    @moduledoc "The auction's chain: Base's chain id, and its head for any block asked for."
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(head), do: head

    @impl true
    def call(conn, head) do
      {:ok, body, conn} = read_body(conn)
      %{"id" => id, "method" => method} = Jason.decode!(body)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{jsonrpc: "2.0", id: id, result: result(method, head)}))
    end

    defp result("eth_chainId", _head), do: "0x2105"
    defp result("eth_getBlockByNumber", head), do: head
  end

  setup do
    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    now = DateTime.utc_now()
    dir = Path.join(System.tmp_dir!(), "share-video-render-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    restored(:share_video_saved_bytes)
    chain(dir, now)
    ffmpeg(dir)

    auction =
      TestSupport.project_auction(
        chain_id: 8453,
        symbol: "RENDER",
        state: :active,
        opened_at: DateTime.add(now, -3600)
      )

    Ash.update!(auction, %{floor_price: "0.001", token_supply: Decimal.new(1_000_000_000)},
      action: :refresh_lab_market,
      actor: %Autolaunch.Actors.System{}
    )

    %{auction: auction, now: now}
  end

  test "RENDER_HONOURS_SAVED_SPACE: a video made past the line is served but not saved",
       %{auction: auction, now: now} do
    # Just under the line: the video is saved and served every time.
    space(held() + 1)
    assert {:waiting, _ahead} = ShareVideo.fetch(auction, :auction, nil, nil, now)
    render()
    assert [%{state: "ready", saved: true, mp4: @mp4}] = stored(auction)
    assert ShareVideo.fetch(auction, :auction, nil, nil, now) == {:ok, @mp4}
    assert ShareVideo.fetch(auction, :auction, nil, nil, now) == {:ok, @mp4}

    # At the line, and past it: still made and handed over once, never saved,
    # and asking again makes another. Each is a new quarter hour's video.
    for {past, minutes} <- [{0, 15}, {1, 30}] do
      later = DateTime.add(now, minutes * 60)
      space(held() - past)
      assert {:waiting, _ahead} = ShareVideo.fetch(auction, :auction, nil, nil, later)
      render()
      assert %{state: "ready", saved: false, mp4: @mp4} = auction |> stored() |> List.last()
      assert ShareVideo.fetch(auction, :auction, nil, nil, later) == {:ok, @mp4}
      assert %{saved: false, mp4: nil} = auction |> stored() |> List.last()
      assert {:waiting, _ahead} = ShareVideo.fetch(auction, :auction, nil, nil, later)
    end
  end

  # Runs the queued render jobs, as the site's share-video queue does.
  defp render, do: Oban.drain_queue(queue: :share_videos)

  defp space(bytes), do: Application.put_env(:autolaunch, :share_video_saved_bytes, bytes)

  # Every byte of made video held, as the saved space counts it.
  defp held do
    %{rows: [[held]]} =
      Repo.query!(
        "SELECT coalesce(sum(octet_length(mp4)), 0) FROM autolaunch_app.share_video_requests"
      )

    held
  end

  # The auction's requests that have finished, oldest first.
  defp stored(auction) do
    Repo.all(
      from(r in "share_video_requests",
        where: r.auction_id == type(^auction.id, :binary_id) and r.state != "queued",
        order_by: r.inserted_at,
        select: %{state: r.state, saved: r.saved, mp4: r.mp4}
      )
    )
  end

  # A Base deployment description like the tests' own, whose node is `Node`.
  defp chain(dir, now) do
    head = %{
      "number" => "0x64",
      "hash" => "0x" <> String.duplicate("ab", 32),
      "timestamp" => "0x" <> Integer.to_string(DateTime.to_unix(now), 16)
    }

    server =
      start_supervised!(
        {Bandit, plug: {Node, head}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    deployment = Path.join(dir, "base-deployment.json")

    Application.fetch_env!(:autolaunch, :autolaunch_base_deployment)
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("rpc_url", "http://127.0.0.1:#{port}")
    |> Jason.encode!()
    |> then(&File.write!(deployment, &1))

    restored(:autolaunch_base_deployment)
    Application.put_env(:autolaunch, :autolaunch_base_deployment, deployment)
  end

  # An `ffmpeg` first on the PATH that takes every frame from its input and
  # writes the fixed MP4 to the file it is given last.
  defp ffmpeg(dir) do
    File.write!(Path.join(dir, "made.mp4"), @mp4)
    script = Path.join(dir, "ffmpeg")

    File.write!(script, """
    #!/bin/sh
    cat > /dev/null
    for out; do :; done
    cat "#{dir}/made.mp4" > "$out"
    """)

    File.chmod!(script, 0o755)
    path = System.fetch_env!("PATH")
    System.put_env("PATH", dir <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)
  end

  defp restored(key) do
    previous = Application.fetch_env!(:autolaunch, key)
    on_exit(fn -> Application.put_env(:autolaunch, key, previous) end)
  end
end
