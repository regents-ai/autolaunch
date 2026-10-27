defmodule AutolaunchWeb.TokenPageFirstScreenTest do
  @moduledoc """
  A token's page opens on what a buyer asks first: its price, market cap and
  how far it has moved, with who made it, before its chart and its trade
  widget, in that order in the page, so a phone shows them in that order too.
  The chart button never says the chart is unavailable.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Actors.System
  alias Autolaunch.TestSupport
  alias AutolaunchWeb.Paths

  test "the price, market cap, change and creator come before the chart and the trade widget",
       %{conn: conn} do
    stored =
      TestSupport.project_auction(
        chain_id: 8453,
        symbol: "FIRST",
        state: :graduated,
        token_address: "0x4444444444444444444444444444444444444444"
      )

    Autolaunch.refresh_lab_market_auction!(
      stored,
      :graduated,
      "1",
      %{token_supply: Decimal.new(1_000_000)},
      actor: %System{}
    )

    {:ok, auction} = Paths.find_auction("FIRST", String.slice(stored.auction_address, -5, 5))
    token = TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    Autolaunch.set_subject_token_price!(token, "0.002", "pool", DateTime.utc_now(),
      actor: %System{}
    )

    {:ok, view, _html} = live(conn, Paths.token(auction))
    html = render_async(view, 5_000)

    order =
      Enum.map(
        ["creator-label", ~s(id="token-figures"), ~s(id="trade")],
        &(:binary.match(html, &1) |> elem(0))
      )

    assert order == Enum.sort(order)

    figures = view |> element("#token-figures") |> render()
    assert figures =~ "0.002"
    assert figures =~ "2,000.00 REGENT"
    refute html =~ "Chart unavailable"
  end
end
