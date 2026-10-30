defmodule AutolaunchWeb.LaunchesPausedTest do
  @moduledoc """
  Base's launchers stop taking new launches before Base's faster blocks
  (Sean, 30 Oct 2026, "1. a"). The create page says so from the chain's own
  `launchesPaused()`, so nobody fills in a launch Base is certain to refuse.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.LaunchFixture

  @note "New launches are paused until the new version opens."

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
  end

  test "LAUNCHES_PAUSED_FROM_CHAIN: the Revstake create page names the pause only while Base reads it",
       %{conn: conn} do
    LaunchFixture.install(paused: true)
    {:ok, view, _html} = live(conn, "/create/revstake")
    assert render_async(view) =~ @note

    LaunchFixture.install(paused: false)
    {:ok, view, _html} = live(build_conn(), "/create/revstake")
    refute render_async(view) =~ @note
  end
end
