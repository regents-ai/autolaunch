defmodule AutolaunchWeb.ThemeTest do
  use AutolaunchWeb.ConnCase, async: true

  test "the document carries the Autolaunch brand and the dark default", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(data-brand="autolaunch")
    assert html =~ ~s(data-theme="dark")
  end

  test "the document tells the browser which schemes it supports", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(<meta name="color-scheme" content="dark light">)
  end
end
