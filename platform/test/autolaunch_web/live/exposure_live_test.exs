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
  # The page's panels each read the stubbed chain; a busy machine needs more than 100ms.
  @async 2_000

  test "switched off, the page is not found", %{conn: conn} do
    {404, _headers, _body} = assert_error_sent(404, fn -> get(conn, "/after-hour-stocks") end)
  end

  test "the page shows both tokens' values, their pools and every price applied", %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/after-hour-stocks")
    html = render_async(view, @async)

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

  test "the page offers Share, and a link to it previews the series", %{conn: conn} do
    ExposureChain.install()
    html = conn |> get("/after-hour-stocks") |> html_response(200)

    assert html =~ ~s(content="Isolated Exposure to After-hours Stocks on Autolaunch")
    assert html =~ "/after-hour-stocks?series=#{@series}"

    {:ok, view, _html} = live(conn, "/after-hour-stocks")
    render_async(view, @async)
    assert has_element?(view, "#exposure-share")
  end

  test "before the first close, minting waits and no values are shown", %{conn: conn} do
    ExposureChain.install(%{status: 0, prices: [], accounted: 0, held: 0, supply: 0})
    {:ok, view, _html} = live(conn, "/after-hour-stocks")
    html = render_async(view, @async)

    assert html =~ "Opens after the close on Fri 30 Oct, 4:00pm"
    refute has_element?(view, "[id^=exposure-print-]")
  end

  test "a leg without a pool says so, and one without liquidity shows no price", %{conn: conn} do
    ExposureChain.install(%{
      pools: %{ExposureChain.session() => {"0x4444444444444444444444444444444444444444", nil}}
    })

    {:ok, view, _html} = live(conn, "/after-hour-stocks")
    render_async(view, @async)

    assert view |> element("#exposure-overnight") |> render() =~ "No pool yet"
    assert view |> element("#exposure-session") |> render() =~ "No liquidity"
  end

  test "the Return tab returns pairs before the end and each token after it", %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/after-hour-stocks?tab=return")
    render_async(view, @async)

    assert has_element?(view, "#exposure-redeem-#{@series} input[name=pairs]")
    assert has_element?(view, "#exposure-redeem-#{@series} [data-onchain-step=redeem]")

    ExposureChain.put(%{status: 2, end_reason: 1})
    {:ok, view, _html} = live(conn, "/after-hour-stocks?tab=return")
    render_async(view, @async)

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
    render_async(view, @async)

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
    render_async(view, @async)

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

  # Found by the copy-of-Base journey: the last price ended the series while a
  # Record panel was still open, and the panel's next read of the steps crashed.
  test "a series that ends while the Record panel is open says it has ended", %{conn: conn} do
    ExposureChain.install()
    {view, panel} = signed_in_panel(conn, "#exposure-update-#{@series}")
    ExposureChain.put(%{status: 2, end_reason: 1})

    render_hook(panel, "change", %{})
    render_async(view, @async)

    assert has_element?(view, "#exposure-update-#{@series}", "This series has ended")
    assert has_element?(view, "#exposure-update-#{@series} [data-onchain-step=settle][disabled]")
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

  test "the portfolio lists the tokens a wallet holds, their value and a way back to Return", %{
    conn: conn
  } do
    ExposureChain.install(%{
      wallet: %{stock: 0, allowance: 0, overnight: 10_000_000, session: 5_000_000}
    })

    {view, _account} = signed_in(conn, "/portfolio")
    render_async(view, @async)
    row = "#portfolio-exposure-#{@series}"

    # 0.1 After-hours at $131 and 0.05 Market-hours at $125.
    assert has_element?(view, row, "AMZNc to Fri 6 Nov, 4:00pm")
    assert has_element?(view, "#{row} td[data-label=After-hours]", "0.1")
    assert has_element?(view, "#{row} td[data-label=Market-hours]", "0.05")
    assert has_element?(view, "#{row} td[data-label=Value]", "$19.35")

    assert has_element?(
             view,
             "#{row} a[href='/after-hour-stocks?series=#{@series}&tab=return']",
             "Return"
           )
  end

  test "the portfolio points a wallet without tokens to the page", %{conn: conn} do
    ExposureChain.install()
    {view, _account} = signed_in(conn, "/portfolio")
    render_async(view, @async)

    assert has_element?(view, "#portfolio-exposure", "No tokens yet")
    assert has_element?(view, "#portfolio-exposure a[href='/after-hour-stocks']")
  end

  # Found by the logic review: after the end the tokens showed dollars frozen at the
  # last price, though each is then a fixed share of the stock.
  test "after the end each token is shown as the stock it returns", %{conn: conn} do
    ExposureChain.install(%{
      status: 2,
      end_reason: 1,
      wallet: %{stock: 0, allowance: 0, overnight: 10_000_000, session: 5_000_000}
    })

    {:ok, view, _html} = live(conn, "/after-hour-stocks")
    render_async(view, @async)

    # After-hours ends at $131 of the $256 price: 131/256 of one AMZNc.
    assert view |> element("#exposure-overnight") |> render() =~ "0.51171875 AMZNc"
    assert view |> element("#exposure-overnight") |> render() =~ "With AMZNc"

    {view, _account} = signed_in(conn, "/portfolio")
    render_async(view, @async)

    # 0.1 × 131/256 + 0.05 × 125/256 AMZNc, rounded down as the series pays it.
    assert has_element?(
             view,
             "#portfolio-exposure-#{@series} td[data-label=Value]",
             "0.07558593 AMZNc"
           )
  end

  # Found by the logic review: "0,4" was read as 4.
  test "an amount typed with a comma is refused and says how to write it", %{conn: conn} do
    ExposureChain.install()
    {view, _panel} = signed_in_panel(conn, "#exposure-mint-#{@series}")

    view |> element("#exposure-mint-#{@series}-form") |> render_change(%{"amount" => "0,04"})
    render_async(view, @async)

    assert has_element?(
             view,
             "#exposure-mint-#{@series}",
             "Write amounts with a point, as in 0.4."
           )

    refute has_element?(view, "#exposure-mint-#{@series}", "You deposit")
  end

  test "End series is on the page from the start, disabled until the price is overdue", %{
    conn: conn
  } do
    ExposureChain.install()
    {view, _panel} = signed_in_panel(conn, "#exposure-end-#{@series}")

    assert has_element?(view, "#exposure-end-#{@series} [data-onchain-step=end][disabled]")
    assert has_element?(view, "#exposure-end-#{@series}", "Possible after")
  end

  # A new signed-in person on the page, their wallet open.
  defp signed_in_panel(conn, selector) do
    path =
      if selector =~ "redeem", do: "/after-hour-stocks?tab=return", else: "/after-hour-stocks"

    {view, account} = signed_in(conn, path)
    render_async(view, @async)
    panel = with_target(view, selector)
    render_hook(panel, "onchain_active_wallet", %{"address" => account.wallet_address})
    render_async(view, @async)
    {view, panel}
  end

  # A new signed-in person on `path`.
  defp signed_in(conn, path) do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live(path)

    {view, account}
  end
end
