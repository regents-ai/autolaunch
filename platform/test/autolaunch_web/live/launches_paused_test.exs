defmodule AutolaunchWeb.LaunchesPausedTest do
  @moduledoc """
  Base's launchers stop taking new launches before Base's faster blocks
  (Sean, 30 Oct 2026, "1. a"). The create page says so from the chain's own
  `launchesPaused()`, so nobody fills in a launch Base is certain to refuse,
  and reads it again each time the site reads a new block (every five minutes
  on mainnet), so the button comes back once launches reopen.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{BaseRpcStub, ChainHead, LabAbi, LaunchFixture, SharedReading}

  @note "New launches are paused until the new version opens."

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    on_exit(fn ->
      Application.put_env(:autolaunch, :prelaunch_read_only, previous)
      for feed <- ["base", "stocks"], do: SharedReading.delete(ChainHead.key(feed))
    end)
  end

  test "LAUNCHES_PAUSED_FROM_CHAIN: the Revstake create page names the pause only while Base reads it",
       %{conn: conn} do
    LaunchFixture.install(paused: true)
    {:ok, view, _html} = live(conn, "/agent-business")
    assert render_async(view) =~ @note

    LaunchFixture.install(paused: false)
    {:ok, view, _html} = live(build_conn(), "/agent-business")
    refute render_async(view) =~ @note
  end

  # A13: the pause was read once as the page opened, so a button it greyed
  # stayed greyed after launches reopened (money-path audit, 12 Nov 2026).
  test "the Revstake create page reads the pause again each time the site reads a new Base block",
       %{conn: conn} do
    LaunchFixture.install(paused: true)
    {:ok, view, _html} = live(conn, "/agent-business")
    assert render_async(view) =~ @note

    LaunchFixture.install(paused: false)
    new_block("base", 30_000_001)
    refute render_async(view) =~ @note

    LaunchFixture.install(paused: true)
    new_block("base", 30_000_002)
    assert render_async(view) =~ @note
  end

  test "the Memestock create page reads the launchpad's pause again each time the site reads a new block",
       %{conn: conn} do
    BaseRpcStub.install(:autolaunch_lab_http_client, &launchpad/2)

    BaseRpcStub.put(%{
      paused: true,
      blocks: %{
        "latest" => %{
          "number" => "0x100",
          "hash" => BaseRpcStub.receipt_block_hash(),
          "timestamp" => "0x6700"
        }
      }
    })

    {:ok, view, _html} = live(conn, "/create")
    assert render_async(view) =~ @note

    BaseRpcStub.put(%{paused: false})
    new_block("stocks", 256)
    refute render_async(view) =~ @note
  end

  defp new_block(feed, number) do
    :ok = SharedReading.put(ChainHead.key(feed), number)
  end

  # The launchpad answers only `launchesPaused()`; the page's other reads find
  # Base unavailable.
  defp launchpad(%{data: data}, %{paused: paused}) do
    if data == LabAbi.selector("launchesPaused()"),
      do: BaseRpcStub.uint(if(paused, do: 1, else: 0)),
      else: :unavailable
  end
end
