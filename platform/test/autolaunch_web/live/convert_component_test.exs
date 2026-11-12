defmodule AutolaunchWeb.ConvertComponentTest do
  @moduledoc """
  The Convert panel keeps the amount its converter typed when the launch is
  read again with new figures, as it is after every refresh and every landed
  conversion. Only another launch starts the form again.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]
  import Phoenix.LiveViewTest

  setup :bidder

  setup do
    # The site as it runs once launches are open, when the form is offered.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
  end

  # The panel as a page holds it, for the signed-in wallet the fee hook names
  # as its converter. `{:launch, launch}` is the page reading the launch again.
  defmodule Panel do
    use Phoenix.LiveView

    def mount(_params, %{"launch" => launch, "account_id" => account_id} = session, socket) do
      {:ok,
       assign(socket,
         launch: launch,
         pool: pool(session["wallet"]),
         account_id: account_id,
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account_id)
       )}
    end

    def handle_info({:launch, launch}, socket), do: {:noreply, assign(socket, launch: launch)}

    def render(assigns) do
      ~H"""
      <.live_component
        module={AutolaunchWeb.ConvertComponent}
        id="convert"
        launch={@launch}
        pool={@pool}
        authenticated
        current_human_id={@account_id}
        session_lease={@lease}
      />
      """
    end

    defp pool(converter) do
      %{
        kind: :stocks,
        currency: %{symbol: "TSLA"},
        fees: %{
          regent: %{accrued: "40", converter: converter},
          splitter: %{dollar: %{symbol: "USDC"}}
        }
      }
    end
  end

  test "a launch read again with new figures keeps the typed amount; another launch clears it",
       %{conn: conn, account: account, auction: auction, wallet: wallet} do
    launch = %{chain: :base, auction: %{id: auction.id, current_clearing_price: "1"}}
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Panel,
        session: %{"launch" => launch, "account_id" => account.id, "wallet" => wallet}
      )

    view
    |> with_target("#convert")
    |> render_hook("onchain_active_wallet", %{"address" => wallet})

    view |> form("#convert form") |> render_change(%{amount: "12.5"})
    assert has_element?(view, ~s|#convert-amount[value="12.5"]|)

    send(view.pid, {:launch, put_in(launch.auction.current_clearing_price, "2")})
    assert has_element?(view, ~s|#convert-amount[value="12.5"]|)

    send(view.pid, {:launch, put_in(launch.auction.id, Ash.UUID.generate())})
    assert has_element?(view, ~s|#convert-amount[value=""]|)
  end
end
