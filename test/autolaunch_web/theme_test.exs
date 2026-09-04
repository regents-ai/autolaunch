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

  test "shell styles name tokens instead of literal colours" do
    hex = ~r/#[0-9A-Fa-f]{3,8}\b/

    for path <- Path.wildcard("assets/css/shell/*.css") do
      refute File.read!(path) =~ hex, "#{path} must use tokens"
    end
  end
end
