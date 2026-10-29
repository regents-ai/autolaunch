defmodule AutolaunchWeb.ExposureLiveTest do
  @moduledoc """
  `/after-hour-stocks` shows what the series holds: both tokens with what each
  is worth now and its pool price, every price applied so far, the deposits
  against the cap, and the Mint, Return and Record panels; with After-hours
  Exposure switched off the address is not found.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :capture_log

  alias Autolaunch.{ExposureChain, TestSupport}
  alias AutolaunchWeb.OnchainSteps

  @series ExposureChain.series()

  test "switched off, the page is not found", %{conn: conn} do
    {404, _headers, _body} = assert_error_sent(404, fn -> get(conn, "/after-hour-stocks") end)
  end

  test "the page shows both tokens' values, their pools and every price applied", %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/after-hour-stocks")
    html = render_async(view)

    # Close 250 then open 256: After-hours 131, Market-hours 125.
    assert view |> element("#exposure-overnight") |> render() =~ "$131.00"
    assert view |> element("#exposure-overnight") |> render() =~ "51.2% of AMZNc"
    assert view |> element("#exposure-overnight") |> render() =~ "$2.64"
    assert view |> element("#exposure-session") |> render() =~ "$125.00"
    assert view |> element("#exposure-session") |> render() =~ "$2.51"
    assert has_element?(view, "#exposure-print-0", "$250.00")
    assert has_element?(view, "#exposure-print-1", "$256.00")
    assert has_element?(view, "#exposure-chart[data-points='[[0,250.0],[1,256.0]]']", "Up 2.4%")
    assert html =~ "0.1 of 0.4 AMZNc"
    assert html =~ "Live, 2 of 11 prices applied"
    assert html =~ "Fri 30 Oct, 4:00pm to Fri 6 Nov, 4:00pm"
    assert has_element?(view, "a[href='/after-hour-stocks/terms/#{ExposureChain.terms_hash()}']")
  end

  test "before the first close, minting waits and no values are shown", %{conn: conn} do
    ExposureChain.install(%{status: 0, prices: [], accounted: 0, held: 0, supply: 0})
    {:ok, view, _html} = live(conn, "/after-hour-stocks")
    html = render_async(view)

    assert html =~ "Opens after the close on Fri 30 Oct, 4:00pm"
    refute has_element?(view, "[id^=exposure-print-]")
  end

  test "a leg without a pool says so, and one without liquidity shows no price", %{conn: conn} do
    ExposureChain.install(%{
      pools: %{ExposureChain.session() => {"0x4444444444444444444444444444444444444444", nil}}
    })

    {:ok, view, _html} = live(conn, "/after-hour-stocks")
    render_async(view)

    assert view |> element("#exposure-overnight") |> render() =~ "No pool yet"
    assert view |> element("#exposure-session") |> render() =~ "No liquidity"
  end

  test "the Return tab returns pairs before the end and each token after it", %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/after-hour-stocks?tab=return")
    render_async(view)

    assert has_element?(view, "#exposure-redeem-#{@series} input[name=pairs]")
    assert has_element?(view, "#exposure-redeem-#{@series} [data-onchain-step=redeem]")

    ExposureChain.put(%{status: 2, end_reason: 1})
    {:ok, view, _html} = live(conn, "/after-hour-stocks?tab=return")
    render_async(view)

    assert has_element?(view, "#exposure-redeem-#{@series} input[name=overnight]")
    assert has_element?(view, "#exposure-redeem-#{@series} input[name=session]")
  end

  test "a signed-in wallet's panel offers its stock, and mint waits for the approval", %{
    conn: conn
  } do
    ExposureChain.install()
    {view, _panel} = signed_in_panel(conn, "#exposure-mint-#{@series}")

    assert has_element?(view, "#exposure-mint-#{@series}", "Wallet: 0.5 AMZNc")
    view |> element("#exposure-mint-#{@series}-form") |> render_change(%{"amount" => "0.05"})
    render_async(view)

    assert has_element?(
             view,
             "#exposure-mint-#{@series} [data-onchain-step=stock_approval]:not([disabled])"
           )

    assert has_element?(view, "#exposure-mint-#{@series} [data-onchain-step=mint][disabled]")
    assert has_element?(view, "#exposure-mint-#{@series}", "Approve first")
  end

  test "the cap is named when an amount would pass it", %{conn: conn} do
    ExposureChain.install(%{
      wallet: %{stock: 50_000_000, allowance: 50_000_000, overnight: 0, session: 0}
    })

    {view, _panel} = signed_in_panel(conn, "#exposure-mint-#{@series}")

    view |> element("#exposure-mint-#{@series}-form") |> render_change(%{"amount" => "0.35"})
    render_async(view)

    assert has_element?(view, "#exposure-mint-#{@series}", "Only 0.3 AMZNc left under the cap")
  end

  test "the next price can't be recorded before an hour after its time, and says when", %{
    conn: conn
  } do
    ExposureChain.install()
    {view, _panel} = signed_in_panel(conn, "#exposure-update-#{@series}")

    assert has_element?(view, "#exposure-update-#{@series} [data-onchain-step=settle][disabled]")

    assert has_element?(
             view,
             "#exposure-update-#{@series}",
             "Can be recorded from Mon 2 Nov, 5:00pm"
           )
  end

  # A press the panel can't build steps for says so: it never silently does nothing.
  test "a press the chain can't be read for says nothing was sent", %{conn: conn} do
    note = "#exposure-mint-#{@series} [role=status]"
    ExposureChain.install()
    {view, panel} = signed_in_panel(conn, "#exposure-mint-#{@series}")
    ExposureChain.put(%{unreadable: true})

    render_hook(panel, "prepare_and_send", %{"form" => %{"amount" => "0.01"}, "step" => "mint"})
    assert_reply(view, reply)
    assert reply == %{}
    assert has_element?(view, note, OnchainSteps.unsent_note())
  end

  # A new signed-in person on the page, their wallet open.
  defp signed_in_panel(conn, selector) do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    path =
      if selector =~ "redeem", do: "/after-hour-stocks?tab=return", else: "/after-hour-stocks"

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live(path)

    render_async(view)
    panel = with_target(view, selector)
    render_hook(panel, "onchain_active_wallet", %{"address" => account.wallet_address})
    render_async(view)
    {view, panel}
  end
end
