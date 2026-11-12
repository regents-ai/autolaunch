defmodule AutolaunchWeb.CreatePagesTest do
  @moduledoc """
  The two create pages, Memestock at /create and Revstake at /agent-business:
  each keeps a card of the launch beside the form and says what is still
  needed under its button, and Revstake's treasury is a Safe. Closed for
  launches, both addresses answer as unknown.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{LaunchFixture, TestSupport}

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    LaunchFixture.install()
  end

  defp open(conn, path) do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live(path)

    view
  end

  # Sean, 12 Nov 2026, audit finding A4: a Revstake treasury is a Safe, with
  # no single key or other contract to choose instead.
  test "REVSTAKE_TREASURY_IS_A_SAFE: Revstake's card, the still-needed line and a treasury that takes only a Safe's address",
       %{conn: conn} do
    view = open(conn, "/agent-business")

    assert has_element?(view, "#revstake-summary", "Opening price")
    assert has_element?(view, "#revstake-summary", "FDV")
    assert has_element?(view, ".create-page__need", "Still needed")

    fields =
      view
      |> element("#launch-treasury-details")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input, select, textarea")
      |> LazyHTML.attribute("name")

    assert fields == ["launch_draft[treasury]"]

    assert has_element?(
             view,
             "#launch-treasury-details a[href='https://app.safe.global/new-safe/create?chain=base']"
           )

    assert has_element?(view, "#revstake-summary", "Safe")
  end

  test "the Memestock page keeps the same card and still-needed line", %{conn: conn} do
    view = open(conn, "/create")

    assert has_element?(view, "#create-preview", "Opening price")
    assert has_element?(view, ".create-page__need", "Still needed")
  end

  test "closed for launches, both create addresses answer as unknown", %{conn: conn} do
    Application.put_env(:autolaunch, :prelaunch_read_only, true)

    for path <- ["/create", "/agent-business"],
        do: assert(conn |> get(path) |> response(404))
  end
end
