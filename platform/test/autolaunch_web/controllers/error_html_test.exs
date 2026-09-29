defmodule AutolaunchWeb.ErrorHTMLTest do
  use AutolaunchWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    html = render_to_string(AutolaunchWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Not Found"
    assert html =~ ~s(data-brand="autolaunch")
    assert html =~ "rg-frame"
    assert html =~ "rg-button__label"
  end

  test "renders 500.html" do
    html = render_to_string(AutolaunchWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Internal Server Error"
    assert html =~ ~s(href="/")
    assert html =~ "rg-frame"
  end
end
