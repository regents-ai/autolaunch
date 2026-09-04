defmodule AutolaunchWeb.SubjectsLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  test "the empty subjects index keeps its identifier and copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/subjects")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-subjects")
    assert html =~ "Subjects"
    assert html =~ "No public subjects yet."
  end

  test "the listed subjects index shows a public row and hides a nil-creator auction", %{
    conn: conn
  } do
    hidden_id = TestSupport.insert_null_creator_auction!()

    subject =
      TestSupport.project_subject(
        subject_id: "subject:index:listed",
        token_address: "0x3333333333333333333333333333333333333333"
      )

    {:ok, view, _html} = live(conn, ~p"/subjects")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-subjects")
    assert html =~ subject.subject_id
    assert html =~ ~s(href="/subjects/#{subject.subject_id}")
    refute html =~ hidden_id
    refute html =~ "Hidden"
  end
end
