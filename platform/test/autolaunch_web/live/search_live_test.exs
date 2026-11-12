defmodule AutolaunchWeb.SearchLiveTest do
  @moduledoc """
  The search window answers a search that reaches it before its browser said
  it had opened, as happens when a page connects again while the window is
  open: the results are listed with their figures.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  @moduletag :capture_log

  setup do
    # The site as it runs once launches are open, when the window is on the page.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
  end

  test "a search that arrives before the window opened lists its results", %{conn: conn} do
    TestSupport.project_auction(chain_id: 8453, symbol: "EARLY", title: "Early Bird")
    {:ok, view, _html} = live_isolated(conn, AutolaunchWeb.SearchLive)

    render_hook(view, "search", %{"q" => "EARLY"})

    assert render_async(view) =~ "Early Bird"
    assert has_element?(view, "[data-search-result] .search-result__figures")
  end
end
