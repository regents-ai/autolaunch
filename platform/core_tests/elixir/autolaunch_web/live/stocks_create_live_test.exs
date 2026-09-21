defmodule AutolaunchWeb.StocksCreateLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}

  @aapl "0xb200000000000000000000C2e324d24d7eEcd1fb"
  @amzn "0xb200000000000000000000d9192b6B456483C2E8"
  @wallet "0x1111111111111111111111111111111111111111"

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> restore(previous) end)

    account =
      Accounts.register_verified!(
        "did:privy:stocks-create:#{Elixir.System.unique_integer([:positive])}",
        @wallet,
        [@wallet],
        actor: %System{}
      )

    {:ok, account: account}
  end

  test "autosaves each section and clears the amounts when the stock changes", %{
    conn: conn,
    account: account
  } do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/create?kind=stocks")

    view
    |> form("#stocks-token-details", stock_draft: %{name: "Apple Pair", symbol: "APLP"})
    |> render_change()

    view
    |> form("#stocks-terms",
      stock_draft: %{stock_address: @aapl, required_raise: "500", floor_price: "1.25"}
    )
    |> render_change()

    actor = %Human{human_account_id: account.id}
    {:ok, draft} = Autolaunch.get_my_stocks_launch_draft(:base, actor: actor)
    assert draft.name == "Apple Pair"
    assert draft.symbol == "APLP"
    assert draft.stock_address == @aapl
    assert draft.required_raise == "500"
    assert draft.floor_price == "1.25"

    html =
      view
      |> form("#stocks-terms", stock_draft: %{stock_address: @amzn})
      |> render_change()

    {:ok, changed} = Autolaunch.get_my_stocks_launch_draft(:base, actor: actor)
    assert changed.stock_address == @amzn
    assert changed.required_raise == nil
    assert changed.floor_price == nil
    refute html =~ ~s(value="1.25")
    refute html =~ ~s(value="500")
    assert html =~ "Saved to your account"

    # With every section complete the wallet step appears, waiting for a wallet.
    view
    |> form("#stocks-terms", stock_draft: %{required_raise: "250", floor_price: "2"})
    |> render_change()

    view
    |> form("#stocks-token-details",
      stock_draft: %{
        description: "Pair",
        website: "https://example.com"
      }
    )
    |> render_change()

    # The image a launch carries is always one the site stored and serves.
    {:ok, draft_for_image} = Autolaunch.get_my_stocks_launch_draft(:base, actor: actor)

    {:ok, %{draft: _attached}} =
      Autolaunch.Stocks.LaunchDraftImageStorage.store_and_attach(
        draft_for_image,
        File.read!("core_tests/elixir/support/fixtures/launch-draft.png"),
        "image/png",
        "launch.png",
        actor
      )

    # The page picks the stored image up with its next save.
    html =
      view
      |> form("#stocks-terms", stock_draft: %{floor_price: "2"})
      |> render_change()

    {:ok, complete} = Autolaunch.get_my_stocks_launch_draft(:base, actor: actor)
    assert Autolaunch.Stocks.LaunchDraft.launch_ready?(complete)
    assert html =~ ~s(id="autolaunch-stocks-launch-wallet-#{complete.id}")
    assert html =~ "Connect or switch wallet"
  end

  defp restore(nil), do: Application.delete_env(:autolaunch, :prelaunch_read_only)
  defp restore(value), do: Application.put_env(:autolaunch, :prelaunch_read_only, value)
end
