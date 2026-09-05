defmodule AutolaunchWeb.LaunchesLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  test "the empty launches index keeps its identifier and copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/launches")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-launches")
    assert html =~ "Launches"
    assert html =~ "No public launches yet."
  end

  test "the listed launches index shows a public row and hides a nil-creator auction", %{
    conn: conn
  } do
    hidden_id = TestSupport.insert_null_creator_auction!()

    launch =
      TestSupport.project_launch(job_id: "launch:index:listed", token_name: "Listed Launch")

    {:ok, view, _html} = live(conn, ~p"/launches")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-launches")
    assert html =~ "Listed Launch"
    assert html =~ ~s(href="/launches/#{launch.job_id}")
    refute html =~ hidden_id
    refute html =~ "Hidden"
  end
end
