defmodule AutolaunchWeb.StocksCreateLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.{Accounts, Repo}
  alias Autolaunch.Actors.{Human, System}

  @aapl "0xb200000000000000000000c2e324d24d7eecd1fb"
  @amzn "0xb200000000000000000000d9192b6b456483c2e8"
  @route "0x547f3b931eaf75bab98364ab396058ddc2e68e4a"
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

    # The picker offers the stocks the last read of the launchpad saved.
    for {address, symbol, name} <- [{@aapl, "AAPLc", "Apple Inc."}, {@amzn, "AMZNc", "Amazon"}] do
      Autolaunch.record_stock_admission!(
        %{
          chain_id: 8453,
          address: address,
          symbol: symbol,
          name: name,
          decimals: 8,
          route: @route,
          admitted: true
        },
        actor: %System{}
      )
    end

    {:ok, account: account}
  end

  test "autosaves each section and states the fixed minimum for the chosen stock", %{
    conn: conn,
    account: account
  } do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/create")

    view
    |> form("#stocks-token-details", stock_draft: %{name: "Apple Pair", symbol: "APLP"})
    |> render_change()

    view
    |> form("#stocks-terms", stock_draft: %{stock_address: @aapl})
    |> render_change()

    actor = %Human{human_account_id: account.id}
    {:ok, draft} = Autolaunch.get_my_stocks_launch_draft(actor: actor)
    assert draft.name == "Apple Pair"
    assert draft.symbol == "APLP"
    assert draft.stock_address == @aapl

    html =
      view
      |> form("#stocks-terms", stock_draft: %{stock_address: @amzn})
      |> render_change()

    {:ok, changed} = Autolaunch.get_my_stocks_launch_draft(actor: actor)
    assert changed.stock_address == @amzn
    assert html =~ "Saved"
    # The whole sale at the lowest starting price, rounded down to four
    # significant digits of the 8-decimal stock.
    assert html =~ "0.269 AMZNc"

    view
    |> form("#stocks-token-details",
      stock_draft: %{
        description: "Pair",
        website: "https://example.com"
      }
    )
    |> render_change()

    # The image a launch carries is always one the site stored and serves.
    {:ok, draft_for_image} = Autolaunch.get_my_stocks_launch_draft(actor: actor)

    {:ok, %{draft: _attached}} =
      Autolaunch.Stocks.LaunchDraftImageStorage.store_and_attach(
        draft_for_image,
        File.read!("test/support/fixtures/launch-draft.png"),
        "image/png",
        "launch.png",
        actor
      )

    # The page picks the stored image up with its next save.
    html =
      view
      |> form("#stocks-terms", stock_draft: %{stock_address: @amzn})
      |> render_change()

    {:ok, complete} = Autolaunch.get_my_stocks_launch_draft(actor: actor)
    assert Autolaunch.Stocks.LaunchDraft.launch_ready?(complete)
    assert html =~ ~s(id="autolaunch-stocks-launch-wallet-#{complete.id}")
    assert html =~ "Review launch"
  end

  # STOCK_LIST_UNREAD_SAYS_SO: a stock list the database could not give
  # crashed /create into the site's "Something went wrong" page.
  test "STOCK_LIST_UNREAD_SAYS_SO: a stock list that can't be read says so, with Try again", %{
    conn: conn,
    account: account
  } do
    session = signed_in_session(account.id)

    # Lasts only as long as this case's sandboxed transaction: the stock list
    # read fails with 42P01 (undefined_table).
    Repo.query!("ALTER TABLE autolaunch_app.stocks RENAME TO stocks_unreadable")

    {{:ok, view, html}, log} =
      with_log(fn ->
        conn
        |> Phoenix.ConnTest.init_test_session(session)
        |> connects_with(session)
        |> live("/create")
      end)

    assert html =~ "The stock list couldn’t be read right now."

    assert view
           |> element("#stocks-terms-stock_address-unread button", "Try again")
           |> has_element?()

    refute html =~ "Something went wrong"
    assert log =~ "stock list read failed: Ash.Error."
    refute log =~ "stocks_unreadable"

    # Once the list can be read, Try again shows the gallery.
    Repo.query!("ALTER TABLE autolaunch_app.stocks_unreadable RENAME TO stocks")

    html =
      view
      |> element("#stocks-terms-stock_address-unread button", "Try again")
      |> render_click()

    refute html =~ "The stock list couldn’t be read right now."
    assert html =~ "AAPLc"
  end

  defp restore(nil), do: Application.delete_env(:autolaunch, :prelaunch_read_only)
  defp restore(value), do: Application.put_env(:autolaunch, :prelaunch_read_only, value)
end
