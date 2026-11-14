defmodule AutolaunchWeb.ExposureLiveTest do
  @moduledoc """
  `/stock/isolated-afters` shows one week of the version 2 factory: this week,
  or a past one by `?week=`. Each state reads as the chain says it: not open
  yet, opening paused, live with prices applied or waiting, the feed
  unreadable, ended for each reason. The panels deposit, redeem, trade and
  update prices; with Exposure switched off the address is not found.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :capture_log

  alias Autolaunch.{ExposureChain, TestSupport}
  alias AutolaunchWeb.OnchainSteps

  @week ExposureChain.week()
  @wad ExposureChain.wad()
  @boundaries ExposureChain.boundaries()
  # Week 2967 ran to its end with every price at 250.
  @past %{(@week - 1) => %{status: 2, end_reason: 1, prices: List.duplicate(250 * @wad, 11)}}

  test "switched off, the page is not found", %{conn: conn} do
    {404, _headers, _body} = assert_error_sent(404, fn -> get(conn, "/stock/isolated-afters") end)
  end

  test "a live week shows each token's ledger, stock claim, leverage and pool, and every open and close",
       %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    html = render_async(view)

    # Close 250 then open 256: After-hours 131, Market-hours 125.
    assert view |> element("#exposure-overnight") |> render() =~ "$131.00"

    # 131/256 of one AMZNc, provisional while prices still move it; 256/131 times the stock's move.
    assert view |> element("#exposure-overnight") |> render() =~ "0.51171875 AMZNc"
    assert view |> element("#exposure-overnight") |> render() =~ "provisional"
    assert view |> element("#exposure-overnight") |> render() =~ "2.0×"
    assert view |> element("#exposure-overnight") |> render() =~ "Pool price $2.64"
    assert view |> element("#exposure-session") |> render() =~ "$125.00"
    assert view |> element("#exposure-session") |> render() =~ "$2.51"

    assert has_element?(view, "#exposure-price-0[data-state=applied]", "$250.00")
    assert has_element?(view, "#exposure-price-1[data-state=applied]", "$256.00")
    assert has_element?(view, "#exposure-price-2[data-state=upcoming]", "Upcoming")

    assert has_element?(
             view,
             "#exposure-price-10[data-state=upcoming]",
             "Close, Fri 20 Nov, 4:00pm"
           )

    assert has_element?(view, "#exposure-chart[data-points='[[0,250.0],[1,256.0]]']", "Up 2.4%")

    assert has_element?(view, "#exposure-week", "16–20 Nov")
    assert has_element?(view, "#exposure-status", "Live, 2 of 11 prices applied")
    assert html =~ "0.1 of 0.4 AMZNc"
    assert has_element?(view, "#exposure-room", "0.3 AMZNc")
    assert has_element?(view, "#exposure-next", "Close, Mon 16 Nov, 4:00pm, applies from 5:00pm")

    # Every action the week offers, Update prices among them and pressable.
    assert has_element?(view, ".token-trade__tabs[data-tabs='4']")

    for tab <- ~w(buy sell deposit redeem),
        do: assert(has_element?(view, "#exposure-act-tab-#{tab}"))

    assert has_element?(
             view,
             "#exposure-update [data-onchain-step=settle]:not([disabled])",
             "Update prices"
           )

    assert has_element?(
             view,
             "a#exposure-terms[href='/stock/isolated-afters/terms/#{ExposureChain.terms_hash()}']"
           )

    assert has_element?(view, "#exposure-address-factory")
    assert has_element?(view, "#exposure-details", "Series")
    refute has_element?(view, "#exposure-weeks")
  end

  test "the page says version 1 stays redeemable and links both of its series", %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)

    for {id, series} <- [
          first: "0xcae5aad4cc21700b32931404c366efd4fc1ddfa0",
          second: "0x1df53a86c8260c20ab79b5f620544209bd454266"
        ] do
      assert has_element?(
               view,
               "#exposure-version-#{id}[href='https://basescan.org/address/#{series}']"
             )
    end
  end

  test "this week before its first deposit is shown at the address it will open at, taking only a deposit",
       %{conn: conn} do
    ExposureChain.install(%{week: %{opened: false}})
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)

    assert has_element?(view, "#exposure-status", "Opens with the first deposit")
    assert has_element?(view, "#exposure-opens", "Opens with the first deposit.")
    assert has_element?(view, "#exposure-pending", "This week opens with its first deposit.")
    assert has_element?(view, ".token-trade__tabs[data-tabs='1']")
    assert has_element?(view, "#exposure-act-tab-deposit[aria-selected=true]")
    refute has_element?(view, "#exposure-act-tab-buy")
    assert has_element?(view, "#exposure-room", "0.4 AMZNc")
    assert has_element?(view, "#exposure-overnight", "AMZNc-AH-1120")
    refute has_element?(view, "#exposure-overnight-facts")
    refute has_element?(view, "#exposure-update")
    refute has_element?(view, "#exposure-share")
    refute has_element?(view, "#exposure-paused")
    assert has_element?(view, "#exposure-details", "Opens at")
    refute has_element?(view, "#exposure-address-overnight")

    assert has_element?(
             view,
             "#exposure-deposit-#{@week} [data-onchain-step=deposit]:not([disabled])",
             "Deposit AMZNc"
           )
  end

  test "while opening is paused a week not open yet says so, and its deposit is disabled with the reason",
       %{conn: conn} do
    ExposureChain.install(%{week: %{opened: false}, paused: true})
    {view, _panel} = signed_in_panel(conn, "#exposure-deposit-#{@week}")

    assert has_element?(view, "#exposure-paused", "Opening new weeks is paused")
    view |> element("#exposure-deposit-#{@week}-form") |> render_change(%{"amount" => "0.05"})
    render_async(view)

    assert has_element?(
             view,
             "#exposure-deposit-#{@week} [data-onchain-step=stock_approval]:not([disabled])"
           )

    assert has_element?(view, "#exposure-deposit-#{@week} [data-onchain-step=deposit][disabled]")
    assert has_element?(view, "#exposure-deposit-#{@week}", "Opening new weeks is paused")
  end

  test "each way a week ends is named in plain words", %{conn: conn} do
    for {reason, words} <- [
          {1, "Ended: week complete"},
          {2, "Ended: After-hours reached zero"},
          {3, "Ended: Market-hours reached zero"},
          {4, "Ended: the price feed had no price in the 84 hours before a moment"},
          {5, "Ended: the price feed gave a price that can't be used"},
          {6, "Ended: the price feed couldn't be read for 7 days"}
        ] do
      ExposureChain.install(%{week: %{status: 2, end_reason: reason}})
      {:ok, view, _html} = live(conn, "/stock/isolated-afters")
      render_async(view)

      assert has_element?(view, "#exposure-status", words)
      refute has_element?(view, "#exposure-next")
      assert has_element?(view, "#exposure-price-2[data-state=skipped]", "Not applied")
      refute has_element?(view, "#exposure-update")
    end
  end

  test "prices due but not yet written are counted, and Update prices says how many it writes",
       %{conn: conn} do
    close = Enum.at(@boundaries, 2)
    ExposureChain.install(%{now: close + 3_700, week: %{due: [257 * @wad]}})
    {view, _panel} = signed_in_panel(conn, "#exposure-settle-#{@week}")

    assert has_element?(view, "#exposure-status", "Live, 3 of 11 prices applied")
    assert has_element?(view, "#exposure-price-2[data-state=due]")

    assert has_element?(
             view,
             "#exposure-settle-#{@week} [data-onchain-step=settle]:not([disabled])"
           )

    assert has_element?(view, "#exposure-due", "1 price")
  end

  test "Update prices stays pressable with nothing due, and says when the next price applies", %{
    conn: conn
  } do
    ExposureChain.install()
    {view, _panel} = signed_in_panel(conn, "#exposure-settle-#{@week}")

    assert has_element?(
             view,
             "#exposure-settle-#{@week} [data-onchain-step=settle]:not([disabled])"
           )

    assert has_element?(view, "#exposure-due", "Nothing yet")

    assert has_element?(
             view,
             "#exposure-settle-#{@week}",
             "Close, Mon 16 Nov, 4:00pm, applies from 5:00pm"
           )
  end

  test "a price the series can't read from the feed is named, with when the feed stopped answering",
       %{conn: conn} do
    close = Enum.at(@boundaries, 2)
    ExposureChain.install(%{now: close + 7_200, week: %{unreadable_since: close + 3_700}})
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)

    assert has_element?(
             view,
             "#exposure-unreadable",
             "The price feed hasn't been readable since Mon 16 Nov, 5:01pm New York."
           )

    assert has_element?(view, "#exposure-price-2[data-state=due]", "Due")
    assert has_element?(view, "#exposure-next", "Close, Mon 16 Nov, 4:00pm, due")

    ExposureChain.put(%{now: close + 7_200})
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)
    assert has_element?(view, "#exposure-unreadable", "The price feed can't be read just now.")
  end

  test "past weeks are listed, and one opens by its number with no deposits", %{conn: conn} do
    ExposureChain.install(%{weeks: @past})
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)

    assert has_element?(view, "#exposure-weeks", "Past weeks")
    assert has_element?(view, "#exposure-week-#{@week - 1}", "9–13 Nov · Ended")
    refute has_element?(view, "#exposure-week-current")

    view |> element("#exposure-week-#{@week - 1}") |> render_click()
    assert_patch(view, "/stock/isolated-afters?week=#{@week - 1}")
    render_async(view)

    assert has_element?(view, "#exposure-status", "Ended: week complete")
    assert has_element?(view, ".token-trade__tabs[data-tabs='3']")
    refute has_element?(view, "#exposure-act-tab-deposit")
    assert has_element?(view, "#exposure-week-#{@week - 1}[aria-current=page]")
    assert has_element?(view, "#exposure-week-current", "This week")
    refute has_element?(view, "#exposure-update")
    assert has_element?(view, "#exposure-overnight", "AMZNc-AH-1113")
  end

  test "a week that is neither this week nor one that opened says so", %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/stock/isolated-afters?week=#{@week - 5}")
    render_async(view)

    assert has_element?(view, "#exposure-unknown", "That week hasn't opened on this site.")
    assert has_element?(view, "#exposure-unknown a[href='/stock/isolated-afters']", "This week")
    refute has_element?(view, "#exposure-summary")
  end

  # The light follows the week's own opens and closes, which the page's tests
  # cannot see change in a browser at the right moment.
  test "each token's light is green only in its own window", %{conn: conn} do
    # Monday 11:00 New York, after the open: Market-hours runs.
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)
    assert has_element?(view, "#exposure-session-light[data-running='true']")
    assert has_element?(view, "#exposure-overnight-light[data-running='false']")

    # Saturday, between Friday's close and Monday's open: After-hours runs.
    ExposureChain.install(%{now: ExposureChain.now() - 2 * 86_400, week: %{prices: [250 * @wad]}})
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)
    assert has_element?(view, "#exposure-overnight-light[data-running='true']")
    assert has_element?(view, "#exposure-session-light[data-running='false']")
  end

  test "the page offers Share for a week that opened, and a link to a week previews it", %{
    conn: conn
  } do
    ExposureChain.install()
    html = conn |> get("/stock/isolated-afters?week=#{@week}") |> html_response(200)

    assert html =~ ~s(content="Isolated Exposure to After-hours Stocks on Autolaunch")
    assert html =~ "/stock/isolated-afters?week=#{@week}"
    assert html =~ "/stock/isolated-afters/#{@week}/share.png"

    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)
    assert has_element?(view, "#exposure-share")
  end

  test "a token without a pool or without liquidity says trading opens when liquidity is added",
       %{
         conn: conn
       } do
    ExposureChain.install(%{week: %{pools: %{session: nil}}})
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)

    assert view |> element("#exposure-overnight") |> render() =~
             "Trading opens when liquidity is added."

    assert view |> element("#exposure-session") |> render() =~
             "Trading opens when liquidity is added."

    refute has_element?(view, "#exposure-overnight a", "Trade")
  end

  test "the Redeem tab redeems pairs before the end and each token after it", %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/stock/isolated-afters?tab=redeem")
    render_async(view)

    assert has_element?(view, "#exposure-redeem-#{@week} input[name=pairs]")
    assert has_element?(view, "#exposure-redeem-#{@week} [data-onchain-step=redeem]")

    ExposureChain.put(%{week: %{status: 2, end_reason: 1}})
    {:ok, view, _html} = live(conn, "/stock/isolated-afters?tab=redeem")
    render_async(view)

    assert has_element?(view, "#exposure-redeem-#{@week} input[name=overnight]")
    assert has_element?(view, "#exposure-redeem-#{@week} input[name=session]")
  end

  test "a signed-in wallet's panel offers its stock, and the deposit waits for the approval", %{
    conn: conn
  } do
    ExposureChain.install()
    {view, _panel} = signed_in_panel(conn, "#exposure-deposit-#{@week}")

    assert has_element?(view, "#exposure-deposit-#{@week}", "Wallet: 0.5 AMZNc")
    view |> element("#exposure-deposit-#{@week}-form") |> render_change(%{"amount" => "0.05"})
    render_async(view)

    assert has_element?(
             view,
             "#exposure-deposit-#{@week} [data-onchain-step=stock_approval]:not([disabled])"
           )

    assert has_element?(view, "#exposure-deposit-#{@week} [data-onchain-step=deposit][disabled]")
    assert has_element?(view, "#exposure-deposit-#{@week}", "Approve first")

    assert has_element?(
             view,
             "#exposure-deposit-#{@week}",
             "0.05 AMZNc-AH-1120 and 0.05 AMZNc-MH-1120"
           )
  end

  test "the cap is named when an amount would pass it", %{conn: conn} do
    ExposureChain.install(%{wallet: %{allowance: 50_000_000}})
    {view, _panel} = signed_in_panel(conn, "#exposure-deposit-#{@week}")

    view |> element("#exposure-deposit-#{@week}-form") |> render_change(%{"amount" => "0.35"})
    render_async(view)

    assert has_element?(view, "#exposure-deposit-#{@week}", "Only 0.3 AMZNc left under the cap")
  end

  test "after the week's last close its deposit is disabled with the reason", %{conn: conn} do
    ExposureChain.install(%{now: List.last(@boundaries) + 60, wallet: %{allowance: 50_000_000}})
    {view, _panel} = signed_in_panel(conn, "#exposure-deposit-#{@week}")

    view |> element("#exposure-deposit-#{@week}-form") |> render_change(%{"amount" => "0.05"})
    render_async(view)

    assert has_element?(view, "#exposure-deposit-#{@week} [data-onchain-step=deposit][disabled]")
    assert has_element?(view, "#exposure-deposit-#{@week}", "Deposits have closed")
  end

  # A press the panel can't build steps for says so: it never silently does nothing.
  test "a press the chain can't be read for says nothing was sent", %{conn: conn} do
    note = "#exposure-deposit-#{@week} [role=status]"
    ExposureChain.install()
    {view, panel} = signed_in_panel(conn, "#exposure-deposit-#{@week}")
    ExposureChain.put(%{unreadable: true})

    render_hook(panel, "prepare_and_send", %{
      "form" => %{"amount" => "0.01"},
      "step" => "deposit"
    })

    assert_reply(view, reply)
    assert reply == %{}
    assert has_element?(view, note, OnchainSteps.unsent_note())
  end

  test "the portfolio lists the tokens a wallet holds this week and in past weeks, their value and a way to Redeem",
       %{conn: conn} do
    ExposureChain.install(%{
      week: %{mine: {10_000_000, 5_000_000}},
      weeks: %{(@week - 1) => Map.put(@past[@week - 1], :mine, {0, 4_000_000})},
      wallet: %{stock: 0}
    })

    {view, _account} = signed_in(conn, "/portfolio")
    render_async(view)
    row = "#portfolio-exposure-#{@week}"

    # 0.1 After-hours at $131 and 0.05 Market-hours at $125.
    assert has_element?(view, row, "AMZNc to Fri 20 Nov, 4:00pm")
    assert has_element?(view, "#{row} td[data-label=After-hours]", "0.1")
    assert has_element?(view, "#{row} td[data-label=Market-hours]", "0.05")
    assert has_element?(view, "#{row} td[data-label=Value]", "$19.35")

    assert has_element?(
             view,
             "#{row} a[href='/stock/isolated-afters?tab=redeem&week=#{@week}']",
             "Redeem"
           )

    # Last week ended with both tokens at $125 of $250: half an AMZNc each.
    assert has_element?(view, "#portfolio-exposure-#{@week - 1}", "AMZNc to Fri 13 Nov, 4:00pm")

    assert has_element?(
             view,
             "#portfolio-exposure-#{@week - 1} td[data-label=Value]",
             "0.02 AMZNc"
           )
  end

  test "the portfolio points a wallet without tokens to the page", %{conn: conn} do
    ExposureChain.install()
    {view, _account} = signed_in(conn, "/portfolio")
    render_async(view)

    assert has_element?(view, "#portfolio-exposure", "No tokens yet")
    assert has_element?(view, "#portfolio-exposure a[href='/stock/isolated-afters']", "Deposit")

    # A page in another live session is loaded fresh, not swapped in over the socket.
    assert {:error, {:redirect, %{to: "http://www.example.com/stock/isolated-afters"}}} =
             live_redirect(view, to: "/stock/isolated-afters")
  end

  # Found by the logic review: after the end the tokens showed dollars frozen at the
  # last price, though each is then a fixed share of the stock.
  test "after the end each token is shown as the stock it returns", %{conn: conn} do
    ExposureChain.install(%{
      week: %{status: 2, end_reason: 1, mine: {10_000_000, 5_000_000}},
      wallet: %{stock: 0}
    })

    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)

    # After-hours ends at $131 of the $256 price: 131/256 of one AMZNc.
    assert view |> element("#exposure-overnight") |> render() =~ "0.51171875 AMZNc"
    assert view |> element("#exposure-overnight") |> render() =~ "Moves with AMZNc"
    assert view |> element("#exposure-overnight") |> render() =~ "per token, final"

    {view, _account} = signed_in(conn, "/portfolio")
    render_async(view)

    # 0.1 × 131/256 + 0.05 × 125/256 AMZNc, rounded down as the series pays it.
    assert has_element?(
             view,
             "#portfolio-exposure-#{@week} td[data-label=Value]",
             "0.07558593 AMZNc"
           )
  end

  # Found by the logic review: "0,4" was read as 4.
  test "an amount typed with a comma is refused and says how to write it", %{conn: conn} do
    ExposureChain.install()
    {view, _panel} = signed_in_panel(conn, "#exposure-deposit-#{@week}")

    view |> element("#exposure-deposit-#{@week}-form") |> render_change(%{"amount" => "0,04"})
    render_async(view)

    assert has_element?(
             view,
             "#exposure-deposit-#{@week}",
             "Write amounts with a point, as in 0.4."
           )

    refute has_element?(view, "#exposure-deposit-#{@week}", "You deposit")
  end

  test "a deposit that lands leaves a note with what was received and View portfolio", %{
    conn: conn
  } do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)

    send(view.pid, {:exposure_done, %{kind: "deposit", lines: ["You received 0.05 of each."]}})

    assert has_element?(view, "#exposure-done", "Deposited")
    assert has_element?(view, "#exposure-done", "You received 0.05 of each.")
    assert has_element?(view, "#exposure-done a[href='/portfolio']", "View portfolio")

    view |> element("#exposure-done button[aria-label=Dismiss]") |> render_click()
    refute has_element?(view, "#exposure-done")
  end

  test "with liquid pools the page leads with Buy, and picks which token to buy", %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)

    assert has_element?(view, "#exposure-act-tab-buy[aria-selected=true]")
    assert has_element?(view, "#exposure-leg-after-hours[aria-pressed=true]")
    assert has_element?(view, "#exposure-buy-overnight-#{@week} [data-onchain-step=buy]", "Buy")
    refute has_element?(view, "#exposure-no-liquidity")

    view |> element("#exposure-leg-market-hours") |> render_click()
    assert_patch(view, "/stock/isolated-afters?leg=market-hours&tab=buy")
    render_async(view)
    assert has_element?(view, "#exposure-buy-session-#{@week} [data-onchain-step=buy]")
  end

  test "a signed-in wallet without USDC sees Buy disabled with the reason", %{conn: conn} do
    ExposureChain.install()
    {view, _panel} = signed_in_panel(conn, "#exposure-buy-overnight-#{@week}")

    assert has_element?(view, "#exposure-buy-overnight-#{@week}", "Wallet: 0 USDC")

    view
    |> element("#exposure-buy-overnight-#{@week}-form")
    |> render_change(%{"amount" => "25"})

    render_async(view)

    assert has_element?(
             view,
             "#exposure-buy-overnight-#{@week} [data-onchain-step=buy][disabled]"
           )

    assert has_element?(
             view,
             "#exposure-buy-overnight-#{@week}",
             "Not enough USDC in this wallet"
           )

    assert has_element?(view, "#exposure-buy-overnight-#{@week}", "at least 0.025872")
  end

  # Found by the Buy and Sell review: an empty pool quotes zero, which counted as liquid.
  test "an empty pool is not liquid; with only Market-hours liquid, Buy opens on it", %{
    conn: conn
  } do
    ExposureChain.install(%{week: %{pools: %{overnight: nil, session: nil}}})
    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)
    assert has_element?(view, "#exposure-act-tab-deposit[aria-selected=true]")

    assert view |> element("#exposure-overnight") |> render() =~
             "Trading opens when liquidity is added."

    ExposureChain.put(%{week: %{pools: %{overnight: nil, session: 2_510_000}}})

    {:ok, view, _html} = live(conn, "/stock/isolated-afters")
    render_async(view)
    assert has_element?(view, "#exposure-act-tab-buy[aria-selected=true]")
    assert has_element?(view, "#exposure-leg-market-hours[aria-pressed=true]")
  end

  # A new signed-in person on the page, their wallet open.
  defp signed_in_panel(conn, selector) do
    path =
      cond do
        selector =~ "redeem" -> "/stock/isolated-afters?tab=redeem"
        selector =~ "deposit" -> "/stock/isolated-afters?tab=deposit"
        selector =~ "buy" -> "/stock/isolated-afters?tab=buy"
        true -> "/stock/isolated-afters"
      end

    {view, account} = signed_in(conn, path)
    render_async(view)
    panel = with_target(view, selector)
    render_hook(panel, "onchain_active_wallet", %{"address" => account.wallet_address})
    render_async(view)
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
