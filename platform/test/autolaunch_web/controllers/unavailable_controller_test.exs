defmodule AutolaunchWeb.UnavailableControllerTest do
  use AutolaunchWeb.ConnCase, async: true

  test "the page a visitor is sent to when a page is not offered where they are sits inside the shell" do
    html = build_conn() |> get("/unavailable") |> html_response(200)
    page = LazyHTML.from_document(html)

    assert page |> LazyHTML.query("title") |> LazyHTML.text() =~ "Not available in your region"

    assert page |> LazyHTML.query("#shell-content #unavailable h1") |> LazyHTML.text() ==
             "Not available in your region"

    assert page |> LazyHTML.query("#unavailable p") |> LazyHTML.text() ==
             "This page isn’t offered where you are. The rest of Autolaunch is open to you."

    assert page |> LazyHTML.query("#unavailable a[href='/']") |> LazyHTML.text() |> String.trim() ==
             "Return to Autolaunch"

    assert page |> LazyHTML.query("nav.shell-rail") |> Enum.count() == 1
    assert page |> LazyHTML.query("#shell-apps-button") |> Enum.count() == 1
  end
end
