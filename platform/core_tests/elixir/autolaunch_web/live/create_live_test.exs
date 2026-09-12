defmodule AutolaunchWeb.CreateLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}

  @wallet "0x1111111111111111111111111111111111111111"

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> restore(previous) end)

    account =
      Accounts.register_verified!(
        "did:privy:create:#{Elixir.System.unique_integer([:positive])}",
        @wallet,
        [@wallet],
        actor: %System{}
      )

    {:ok, account: account}
  end

  # The chain named in the address decides which draft the page edits and
  # whether a wallet step exists: Robinhood saves to its own draft in USDG terms
  # and shows no wallet step until its launchpad is live.
  test "the Robinhood address edits the Robinhood draft without a wallet step", %{
    conn: conn,
    account: account
  } do
    session = signed_in_session(account.id)

    {:ok, view, html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/create?chain=robinhood")

    assert html =~ ~s(aria-current="page">Launch on Robinhood)
    assert html =~ "Required raise in USDG"
    assert html =~ "Minimum 5000 USDG"
    assert html =~ ~s(id="launch-robinhood-pending")
    refute html =~ "Complete token details and treasury"

    view
    |> form("#launch-token-details", launch_draft: %{name: "Robinhood only"})
    |> render_change()

    actor = %Human{human_account_id: account.id}

    assert {:ok, %{name: "Robinhood only"}} =
             Autolaunch.get_my_account_launch_draft(:robinhood, actor: actor)

    assert {:ok, nil} = Autolaunch.get_my_account_launch_draft(:base, actor: actor)
  end

  defp restore(nil), do: Application.delete_env(:autolaunch, :prelaunch_read_only)
  defp restore(value), do: Application.put_env(:autolaunch, :prelaunch_read_only, value)
end
