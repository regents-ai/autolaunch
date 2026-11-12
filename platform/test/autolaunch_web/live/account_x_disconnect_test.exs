defmodule AutolaunchWeb.AccountXDisconnectTest do
  @moduledoc """
  On the Account page, an X account that was disconnected leaves its row as
  soon as the browser says so, without a reload: the row offers Connect again.
  Accounts stay open before launches do, so this holds in read-only mode too,
  which is where the row used to stay.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.Human
  alias Autolaunch.TestSupport

  @moduletag :capture_log

  for {mode, read_only?} <- [{"before launches open", true}, {"once launches are open", false}] do
    test "the Profile X row follows a disconnect #{mode}", %{conn: conn} do
      previous = Application.get_env(:autolaunch, :prelaunch_read_only)
      Application.put_env(:autolaunch, :prelaunch_read_only, unquote(read_only?))
      on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)

      account = TestSupport.register_creator!()
      connection = TestSupport.verify_x!(account, :profile, username: "rowfollows")
      session = signed_in_session(account.id)

      {:ok, view, _html} =
        conn
        |> Phoenix.ConnTest.init_test_session(session)
        |> connects_with(session)
        |> live("/account")

      assert has_element?(view, "#account-connections-x-profile [data-x-disconnect-role]")

      Accounts.disconnect_x_connection!(
        connection,
        connection.intent_sequence + 1,
        Ash.UUID.generate(),
        actor: %Human{human_account_id: account.id}
      )

      render_hook(view, "refresh_x_connections", %{
        "role" => "profile",
        "status" => "disconnected"
      })

      refute has_element?(view, "#account-connections-x-profile [data-x-disconnect-role]")
      assert has_element?(view, "#account-connections-x-profile [data-x-connect-role]")
    end
  end
end
