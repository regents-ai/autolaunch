defmodule AutolaunchWeb.CoveredCallsLiveTest do
  @moduledoc """
  `/stock/covered-call` shows what the contract holds: the Buy tab lists only the
  calls still for sale with the amount left, a listing's ticket opens from its
  own address, the Sell ticket's receipt is the quote's for the ticket as it
  stands, the Sell tab lists the open bids with a Sell now ticket each, the Bid
  ticket counts what a bid holds, and with covered calls switched off the
  address is not found and the stock page offers nothing. The portfolio lists
  each listing's and bid's parts, each with its own step.

  A panel works as the token page's Stake does: its button reviews the ticket as
  it stands and opens the wallet steps over it, one wallet button at a time;
  the button is disabled only when the chain makes the action certain to fail.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{CoveredCalls, CoveredCallsChain, Lab, SharedReading, TestSupport}
  alias Autolaunch.CoveredCalls.{PriceLine, Terms}
  alias AutolaunchWeb.CoveredCallsFormat, as: F

  @unit CoveredCallsChain.unit()
  test "switched off, the page is not found and the stock page offers no covered calls",
       %{conn: conn} do
    {404, _headers, _body} = assert_error_sent(404, fn -> get(conn, "/stock/covered-call") end)
    refute conn |> get("/stocks/AMZNc") |> html_response(200) =~ "Covered calls on"
  end

  test "the Buy tab lists only calls still for sale, with the amount left", %{conn: conn} do
    expiry = hd(Terms.expiries(CoveredCallsChain.now()))

    CoveredCallsChain.install(%{
      listings: [
        CoveredCallsChain.listing(%{amount: 10 * @unit, filled: 4 * @unit, strike: 260_000_000}),
        CoveredCallsChain.listing(%{amount: 3 * @unit, filled: 3 * @unit}),
        CoveredCallsChain.listing(%{expiry: expiry - 7 * 86_400})
      ]
    })

    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    html = render_async(view)

    assert has_element?(view, "#covered-call-1")
    refute has_element?(view, "#covered-call-2")
    refute has_element?(view, "#covered-call-3")
    assert html =~ "$260.00"
    assert html =~ "6 AMZNc"

    assert conn |> get("/stocks/AMZNc") |> html_response(200) =~ "Covered calls on AMZNc"
  end

  test "the stock page's link loads the page fresh at its own address", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stocks/AMZNc")
    assert has_element?(view, "a[href='/stock/covered-call']", "Covered calls on AMZNc")

    # A page in another live session is loaded fresh, not swapped in over the socket.
    assert {:error, {:redirect, %{to: "http://www.example.com/stock/covered-call"}}} =
             live_redirect(view, to: "/stock/covered-call")
  end

  test "who may use covered calls is said once, under the page title, and nowhere else",
       %{conn: conn} do
    CoveredCallsChain.install()
    line = "Available to eligible people outside the US."
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    html = render_async(view)
    said = view |> element("h1 + #covered-calls-eligibility") |> render() |> words()

    assert said == line

    assert has_element?(
             view,
             "#covered-calls-eligibility a[href='https://www.coinbase.com/tokenize']"
           )

    assert html |> words() |> String.split(line) |> length() == 2

    for path <- ["/", "/stocks/AMZNc", "/docs", "/llms-full.txt"],
        do: refute(conn |> get(path) |> response(200) =~ line)
  end

  test "a listing's ticket opens from its address with its amount left to buy", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?listing=1")
    render_async(view)

    assert has_element?(view, "#covered-call-buy-1-amount[value='6']")
    assert has_element?(view, "#covered-call-fill-1 button[data-account-target=sign-in]")
  end

  test "with nothing for sale the Buy tab says so", %{conn: conn} do
    CoveredCallsChain.install(%{listings: []})
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    assert render_async(view) =~ "No listings"
  end

  test "selling opens by default on the next four Fridays; Buy counts the calls for sale",
       %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    html = settled(view)

    assert has_element?(view, "#covered-calls-tabs a[data-tab=sell][aria-current=page]")
    assert has_element?(view, "#covered-calls-tabs a[data-tab=buy] .covered-calls__count", "1")

    for expiry <- Terms.expiries(CoveredCallsChain.now()),
        do: assert(has_element?(view, "#covered-calls-sell-expiry button[data-tab='#{expiry}']"))

    assert html =~ "Dividends during the week stay with the tokens"
    assert html =~ "$254.00"
  end

  test "the Sell receipt is the quote's for the ticket as it stands", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    settled(view)
    [first, second | _later] = Terms.expiries(CoveredCallsChain.now())
    form = element(view, "#covered-calls-sell-form")

    # The next Friday and the middle strike, the premium the suggestion.
    render_change(form, %{"amount" => "2", "_target" => ["amount"]})
    settled(view)
    assert_receipt(view, %{expiry: first, amount: 2 * @unit})

    # Another Friday: the suggestions and the receipt follow it.
    view |> element("#covered-calls-sell-expiry button[data-tab='#{second}']") |> render_click()
    settled(view)
    assert_receipt(view, %{expiry: second, amount: 2 * @unit})

    # A strike and premium of the seller's own.
    view |> element("#covered-calls-sell-strike button[data-tab=custom]") |> render_click()
    render_change(form, %{"custom" => "270", "premium" => "4", "_target" => ["premium"]})
    settled(view)

    assert_receipt(view, %{
      expiry: second,
      amount: 2 * @unit,
      strike_per_token: 270_000_000,
      premium_per_token: 4_000_000
    })

    # The way back to the suggestion for that strike.
    view |> element("#covered-calls-sell-suggested") |> render_click()
    settled(view)
    assert_receipt(view, %{expiry: second, amount: 2 * @unit, strike_per_token: 270_000_000})
  end

  test "under the amount, its worth at the reference price, as the quote counts it",
       %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    settled(view)
    [first | _later] = Terms.expiries(CoveredCallsChain.now())

    render_change(element(view, "#covered-calls-sell-form"), %{
      "amount" => "2",
      "_target" => ["amount"]
    })

    settled(view)

    {:ok, %{receipt: receipt}} =
      CoveredCalls.covered_call_quote("AMZNc", %{expiry: first, amount: 2 * @unit}, actor: nil)

    assert text(view, "#covered-calls-sell-value") == "≈ #{F.usd(receipt.reference_value)}"
  end

  test "under You receive, the quote's share of the stock's worth", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    settled(view)
    refute text(view, "#covered-calls-sell-yield") =~ "%"

    [first | _later] = Terms.expiries(CoveredCallsChain.now())

    render_change(element(view, "#covered-calls-sell-form"), %{
      "amount" => "2",
      "_target" => ["amount"]
    })

    settled(view)

    {:ok, quote} =
      CoveredCalls.covered_call_quote("AMZNc", %{expiry: first, amount: 2 * @unit}, actor: nil)

    [percent] =
      Regex.run(~r/([\d.]+)%/, text(view, "#covered-calls-sell-yield"), capture: :all_but_first)

    assert_in_delta String.to_float(percent), quote.receipt.net_premium_yield * 100, 0.005
  end

  test "signed in, the Sell ticket shows the wallet's stock and Max fills the amount with it",
       %{conn: conn} do
    CoveredCallsChain.install(%{balance: 7 * @unit + div(@unit, 2)})
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    settled(view)
    refute has_element?(view, "#covered-calls-sell-balance")

    {view, _panel} = signed_in_sell(conn)
    assert text(view, "#covered-calls-sell-balance") =~ "7.5 AMZNc"

    # Max fills the box in the browser at the press, with the balance as the
    # chain has it, so a press straight after it carries that amount.
    [fill] =
      view
      |> element("#covered-calls-sell-max")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("phx-click")
      |> Enum.flat_map(&JSON.decode!/1)

    assert ["dispatch", %{"event" => "autolaunch:fill", "detail" => %{"value" => value}}] = fill
    assert F.parse_tokens(value, @unit) == 7 * @unit + div(@unit, 2)
  end

  test "an empty wallet's Max is disabled", %{conn: conn} do
    CoveredCallsChain.install(%{balance: 0})
    {view, _panel} = signed_in_sell(conn)
    assert has_element?(view, "#covered-calls-sell-max[disabled]")
  end

  test "a stale reference price leaves the suggested strikes out and keeps the ticket",
       %{conn: conn} do
    CoveredCallsChain.install(%{price: 0})
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    settled(view)

    for choice <- ~w(0 1 2),
        do:
          assert(
            has_element?(
              view,
              "#covered-calls-sell-strike button[data-tab='#{choice}'][disabled]"
            )
          )

    assert has_element?(
             view,
             "#covered-calls-sell-strike button[data-tab=custom]:not([disabled])"
           )

    assert has_element?(
             view,
             "#covered-calls-sell-result [role=status]",
             "No reference price right now"
           )

    assert has_element?(view, "#covered-call-list button[data-account-target=sign-in]")
  end

  test "the Sell ticket's price line: an empty box until the 30 days are read, then the line with the chosen strike across it",
       %{conn: conn} do
    CoveredCallsChain.install()
    forget_line()
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    settled(view)

    assert has_element?(view, "#covered-calls-sell-price-empty")
    refute has_element?(view, "#covered-calls-sell-price-plot")

    # The reader's first read reaches the open page.
    put_line()
    assert [[_at, 250.0] | _] = plot(view, "covered-calls-sell-price", "data-points")
    refute has_element?(view, "#covered-calls-sell-price-empty")

    # Each suggested strike carries its price, which the line takes the moment
    # it is pressed, and the server's level follows once the press reaches it.
    [chosen] = plot(view, "covered-calls-sell-price", "data-levels")
    assert chosen == pill_strike(view, "1")

    assert attribute(view, "#covered-calls-sell-strike button[data-tab=custom]", "data-strike") ==
             "custom"

    view |> element("#covered-calls-sell-strike button[data-tab='0']") |> render_click()
    settled(view)
    assert plot(view, "covered-calls-sell-price", "data-levels") == [pill_strike(view, "0")]
    assert pill_strike(view, "0") < chosen

    # A read that fails leaves the box as it was and draws no line.
    SharedReading.degraded(PriceLine.key("AMZNc"))
    render(view)
    assert has_element?(view, "#covered-calls-sell-price-empty")
    refute has_element?(view, "#covered-calls-sell-price-plot")
  end

  test "the Buy ticket's price line carries the listing's strike and break-even", %{conn: conn} do
    CoveredCallsChain.install()
    forget_line()
    put_line()
    {:ok, view, _html} = live(conn, "/stock/covered-call?listing=1")
    render_async(view)

    assert plot(view, "covered-call-buy-1-price", "data-levels") == [260.0, 263.0]
    assert [_first, _second | _rest] = plot(view, "covered-call-buy-1-price", "data-points")

    # Each is named before its figure; the break-even is the dotted one.
    assert has_element?(
             view,
             "#covered-call-buy-1-price-levels > :first-child:not(.price-line__level--dotted)",
             "Strike"
           )

    assert has_element?(
             view,
             "#covered-call-buy-1-price-levels > .price-line__level--dotted:last-child",
             "Break-even"
           )
  end

  test "the Buy receipt counts the amount typed as the contract does, apart from the prices per token",
       %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?listing=1")
    render_async(view)

    view |> element("#covered-call-buy-1-form") |> render_change(%{"amount" => "2.5"})
    amount = 2 * @unit + div(@unit, 2)

    # For the amount: the premium paid now, the strike a full exercise pays and
    # the stock it delivers.
    assert text(view, "#covered-call-buy-1-pay") ==
             F.usd_due(Terms.usdc_for(amount, 3_000_000, @unit))

    assert text(view, "#covered-call-buy-1-exercise") ==
             F.usd_due(Terms.usdc_for(amount, 260_000_000, @unit))

    assert text(view, "#covered-call-buy-1-get") == "2.5 AMZNc"

    # Per token, whatever the amount.
    assert text(view, "#covered-call-buy-1-strike") |> String.starts_with?(F.usd(260_000_000))
    assert text(view, "#covered-call-buy-1-break-even") |> String.starts_with?(F.usd(263_000_000))

    # An amount that doesn't read leaves the totals empty.
    view |> element("#covered-call-buy-1-form") |> render_change(%{"amount" => "x"})
    assert text(view, "#covered-call-buy-1-exercise") == F.usd(nil)
    assert text(view, "#covered-call-buy-1-get") == F.usd(nil)
  end

  test "Buy calls reviews the amount as typed: the USDC approval, then the purchase",
       %{conn: conn} do
    CoveredCallsChain.install()
    {view, _panel} = signed_in_panel(conn)

    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")

    buy(view, "2")

    refute has_element?(view, "#covered-call-fill-1-review-panel[hidden]")
    assert has_element?(view, "#covered-call-fill-1-review-panel", "You pay")
    assert has_element?(view, "#covered-call-fill-1-review-panel", "$6.00")
    assert has_element?(view, "#covered-call-fill-1-review-panel [data-step=usdc_approval]")
    assert has_element?(view, "#covered-call-fill-1-review-panel [data-step=fill]")

    assert has_element?(
             view,
             "#covered-call-fill-1 [data-onchain-step=usdc_approval]",
             "Approve USDC"
           )

    render_click(element(view, "#covered-call-fill-1-review-panel button[aria-label=Close]"))
    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")
  end

  test "an approval already on the chain shows as done, and the wallet button names the purchase",
       %{conn: conn} do
    CoveredCallsChain.install(%{usdc_allowance: 1_000_000_000})
    {view, _panel} = signed_in_panel(conn)

    buy(view, "1")

    assert has_element?(view, "#covered-call-fill-1 [data-step=usdc_approval][data-state=done]")
    assert has_element?(view, "#covered-call-fill-1 [data-onchain-step=fill]", "Confirm purchase")
  end

  test "a sent approval stays on the page and takes presses, and the purchase's button shows at once",
       %{conn: conn} do
    CoveredCallsChain.install()
    {view, panel} = signed_in_panel(conn)

    buy(view, "1")
    assert_push_event(view, "onchain-steps:review", %{review: %{id: review_id}})

    render_hook(panel, "step_sent", %{
      "review_id" => review_id,
      "step" => "usdc_approval",
      "transaction_hash" => "0x" <> String.duplicate("a", 64)
    })

    # The wallet button names the purchase while the approval is on its way.
    assert has_element?(view, "#covered-call-fill-1 [data-step=usdc_approval][data-state=sent]")

    assert has_element?(
             view,
             "#covered-call-fill-1 .token-swap__wallet-step[data-onchain-step=fill]"
           )

    # Approve is still there for the hook to send again: it names its step, and
    # nothing hides or disables it.
    assert has_element?(
             view,
             "#covered-call-fill-1 .token-swap__approval[data-onchain-step=usdc_approval]:not([disabled]):not([hidden])"
           )
  end

  test "a purchase the wallet can't pay for is disabled with the reason", %{conn: conn} do
    CoveredCallsChain.install(%{usdc_balance: 1_000_000})
    {view, _panel} = signed_in_panel(conn)

    view |> element("#covered-call-buy-1-form") |> render_change(%{"amount" => "2"})
    render_async(view)

    assert has_element?(view, "#covered-call-fill-1-review[disabled]")
    assert has_element?(view, "#covered-call-fill-1-why", "Not enough USDC on Base")
    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")
  end

  # A review that can't be built says so and opens nothing; it never silently does nothing.
  test "a review the chain can't be read for says so and opens nothing", %{conn: conn} do
    CoveredCallsChain.install()
    {view, _panel} = signed_in_panel(conn)
    CoveredCallsChain.put(%{unreadable: true})

    view |> element("#covered-call-fill-1-review") |> render_click()

    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")
    assert has_element?(view, "#covered-call-fill-1-notice", "We couldn't reach Base just now.")
  end

  test "an amount that doesn't read asks for one and opens nothing", %{conn: conn} do
    CoveredCallsChain.install()
    {view, _panel} = signed_in_panel(conn)

    buy(view, "lots")

    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")
    assert has_element?(view, "#covered-call-fill-1-notice", "Enter an amount above zero")
  end

  test "a holder's calls before the window offer Exercise, disabled with when it opens",
       %{conn: conn} do
    CoveredCallsChain.install()
    CoveredCallsChain.put(%{held: 2 * @unit})
    {view, account} = portfolio(conn)

    view
    |> with_target("#portfolio-covered-calls-exercise-1")
    |> render_hook("onchain_active_wallet", %{"address" => account.wallet_address})

    render_async(view)

    assert has_element?(view, "#portfolio-covered-calls-held-1-held", "2 AMZNc")
    assert has_element?(view, "#portfolio-covered-calls-exercise-1-review[disabled]")
    assert has_element?(view, "#portfolio-covered-calls-exercise-1-why", "Opens Fri")
    refute has_element?(view, "#portfolio-covered-calls-held-1-to_collect")
    refute has_element?(view, "#portfolio-covered-calls-claim-1")
  end

  test "an open exercise window comes first on the portfolio, with the time it has left",
       %{conn: conn} do
    now = CoveredCallsChain.now()
    closes = now - 3_600 + Terms.exercise_window()

    # Listing 1 is still for sale; listing 2 is an hour into its window. The
    # wallet holds calls on both.
    CoveredCallsChain.install(%{
      held: 2 * @unit,
      listings: [
        CoveredCallsChain.listing(%{}),
        CoveredCallsChain.listing(%{expiry: now - 3_600})
      ]
    })

    {view, _account} = portfolio(conn)
    html = render(view)

    assert position(html, "portfolio-covered-calls-held-2") <
             position(html, "portfolio-covered-calls-held-1")

    # Counted down in the browser from the chain's time at the reading.
    countdown = "#portfolio-covered-calls-held-2-closes"
    assert has_element?(view, "#{countdown}[data-closes='#{closes}'][data-now='#{now}']")
    assert text(view, countdown) == F.closes_in(closes - now)

    assert has_element?(
             view,
             "#{countdown}-at[datetime='#{DateTime.from_unix!(closes) |> DateTime.to_iso8601()}']"
           )

    refute has_element?(view, "#portfolio-covered-calls-held-1-closes")
  end

  test "a holder's lapsed calls stay listed on the portfolio with nothing left to press",
       %{conn: conn} do
    CoveredCallsChain.install()
    lapsed = hd(Terms.expiries(CoveredCallsChain.now())) - 14 * 86_400

    CoveredCallsChain.put(%{
      listings: [CoveredCallsChain.listing(%{expiry: lapsed})],
      held: 2 * @unit
    })

    {view, _account} = portfolio(conn)

    assert has_element?(view, "#portfolio-covered-calls-held-1", "Closed")
    assert has_element?(view, "#portfolio-covered-calls-held-1-lapsed", "2 AMZNc")
    refute has_element?(view, "#portfolio-covered-calls-exercise-1")
    refute has_element?(view, "#portfolio-covered-calls-claim-1")
  end

  test "a seller's part-sold listing offers to stop selling the rest while it is for sale",
       %{conn: conn} do
    account = TestSupport.register_creator!()

    CoveredCallsChain.install(%{
      listings: [CoveredCallsChain.listing(%{seller: account.wallet_address})]
    })

    {view, _account} = portfolio(conn, account)

    assert has_element?(view, "#portfolio-covered-calls-sold-1-sold", "4 of 10 AMZNc")
    assert has_element?(view, "#portfolio-covered-calls-sold-1-for_sale", "6 AMZNc")

    assert has_element?(
             view,
             "#portfolio-covered-calls-sold-1-for_sale #portfolio-covered-calls-cancel-1"
           )

    refute has_element?(view, "#portfolio-covered-calls-sold-1-exercised")
    refute has_element?(view, "#portfolio-covered-calls-collect_strike-1")
    refute has_element?(view, "#portfolio-covered-calls-claim-1")
  end

  test "in the window a seller's exercised part has its step, and stock buyers can still take is locked, not to collect",
       %{conn: conn} do
    account = TestSupport.register_creator!()

    # An hour into the window: all 4 sold, 1 of those exercised and its strike paid.
    CoveredCallsChain.install(%{
      listings: [
        CoveredCallsChain.listing(%{
          seller: account.wallet_address,
          expiry: CoveredCallsChain.now() - 3_600,
          amount: 4 * @unit,
          exercised: 1 * @unit,
          paid: 260_000_000
        })
      ]
    })

    {view, _account} = portfolio(conn, account)

    assert has_element?(view, "#portfolio-covered-calls-sold-1-sold", "4 of 4 AMZNc")
    assert has_element?(view, "#portfolio-covered-calls-sold-1-exercised", "1 of 4 AMZNc")

    assert has_element?(
             view,
             "#portfolio-covered-calls-sold-1-exercised #portfolio-covered-calls-collect_strike-1"
           )

    assert has_element?(view, "#portfolio-covered-calls-sold-1-locked", "3 AMZNc")
    refute has_element?(view, "#portfolio-covered-calls-sold-1-locked button")
    refute has_element?(view, "#portfolio-covered-calls-sold-1-to_collect")
    refute has_element?(view, "#portfolio-covered-calls-claim-1")

    refute has_element?(view, "#portfolio-covered-calls-cancel-1")
  end

  test "in the window a seller can still stop selling the unsold part", %{conn: conn} do
    account = TestSupport.register_creator!()

    # An hour into the window: 4 of 10 sold, so 6 never sold.
    CoveredCallsChain.install(%{
      listings: [
        CoveredCallsChain.listing(%{
          seller: account.wallet_address,
          expiry: CoveredCallsChain.now() - 3_600
        })
      ]
    })

    {view, _account} = portfolio(conn, account)

    assert has_element?(view, "#portfolio-covered-calls-sold-1-unsold", "6 AMZNc")

    assert has_element?(
             view,
             "#portfolio-covered-calls-sold-1-unsold #portfolio-covered-calls-cancel-1"
           )

    refute has_element?(view, "#portfolio-covered-calls-sold-1-for_sale")
    assert has_element?(view, "#portfolio-covered-calls-sold-1-locked", "4 AMZNc")
    refute has_element?(view, "#portfolio-covered-calls-sold-1-to_collect")
  end

  test "once the window has closed a seller collects all the stock not exercised in one step",
       %{conn: conn} do
    account = TestSupport.register_creator!()

    # Two weeks past the expiry: 4 of 10 sold, 1 of those exercised, so the
    # contract sends back the 6 never sold and the 3 not exercised together.
    CoveredCallsChain.install(%{
      listings: [
        CoveredCallsChain.listing(%{
          seller: account.wallet_address,
          expiry: hd(Terms.expiries(CoveredCallsChain.now())) - 14 * 86_400,
          exercised: 1 * @unit,
          paid: 260_000_000,
          collected: 260_000_000
        })
      ],
      claimable: 9 * @unit
    })

    {view, _account} = portfolio(conn, account)

    assert has_element?(view, "#portfolio-covered-calls-sold-1-to_collect", "9 AMZNc")
    assert has_element?(view, "#portfolio-covered-calls-sold-1-to_collect", "6 unsold")
    assert has_element?(view, "#portfolio-covered-calls-sold-1-to_collect", "3 not exercised")

    assert has_element?(
             view,
             "#portfolio-covered-calls-sold-1-to_collect #portfolio-covered-calls-claim-1"
           )

    # Stopping first is not needed, and nothing is locked any more.
    refute has_element?(view, "#portfolio-covered-calls-cancel-1")
    refute has_element?(view, "#portfolio-covered-calls-sold-1-unsold")
    refute has_element?(view, "#portfolio-covered-calls-sold-1-locked")
  end

  test "before the expiry a seller's sold stock is locked, apart from what is for sale and what the premium paid",
       %{conn: conn} do
    account = TestSupport.register_creator!()

    CoveredCallsChain.install(%{
      listings: [CoveredCallsChain.listing(%{seller: account.wallet_address})]
    })

    {view, _account} = portfolio(conn, account)

    assert has_element?(view, "#portfolio-covered-calls-sold-1-for_sale", "6 AMZNc")
    assert has_element?(view, "#portfolio-covered-calls-sold-1-locked", "4 AMZNc")
    # 4 sold at $3.00 each, less the 1% fee.
    assert has_element?(view, "#portfolio-covered-calls-sold-1-premium", "$11.88")
    refute has_element?(view, "#portfolio-covered-calls-sold-1-to_collect")
  end

  test "the portfolio names the stock by its address, and each row's window by when it opens and closes",
       %{conn: conn} do
    CoveredCallsChain.install()
    CoveredCallsChain.put(%{held: 2 * @unit})
    {view, _account} = portfolio(conn)
    opens = hd(Terms.expiries(CoveredCallsChain.now()))

    assert has_element?(view, "#portfolio-covered-calls-AMZNc-stock", CoveredCallsChain.stock())

    assert has_element?(
             view,
             "#portfolio-covered-calls-AMZNc-contract",
             CoveredCallsChain.contract()
           )

    assert has_element?(
             view,
             ~s|#portfolio-covered-calls-held-1-window-opens[datetime="#{iso(opens)}"]|
           )

    assert has_element?(
             view,
             ~s|#portfolio-covered-calls-held-1-window-closes[datetime="#{iso(opens + 86_400)}"]|
           )
  end

  test "a signed-in holder whose window opens within three days reads when it closes, beside My calls",
       %{conn: conn} do
    opens = CoveredCallsChain.now() + 2 * 86_400

    # The calls held are on listing 1, which no page offers (the next Friday
    # the site offers is more than five days off); the panel is listing 2's.
    CoveredCallsChain.install(%{
      listings: [CoveredCallsChain.listing(%{expiry: opens}), CoveredCallsChain.listing(%{})],
      held: 2 * @unit
    })

    {view, _panel} = signed_in(conn, "/stock/covered-call?listing=2", "#covered-call-fill-2")

    assert has_element?(
             view,
             ~s|#covered-calls-deadline-at[datetime="#{iso(opens + 86_400)}"]|
           )
  end

  test "a holder whose window is more than three days off, or who holds nothing, reads no deadline",
       %{conn: conn} do
    # The next Friday is more than five days off.
    CoveredCallsChain.install(%{held: 2 * @unit})

    {view, _panel} = signed_in_panel(conn)
    refute has_element?(view, "#covered-calls-deadline")

    CoveredCallsChain.put(%{held: 0})
    {view, _panel} = signed_in_panel(build_conn())
    refute has_element?(view, "#covered-calls-deadline")
  end

  test "every ticket and every review names the stock by its address", %{conn: conn} do
    CoveredCallsChain.install(%{bids: [CoveredCallsChain.bid(%{})]})
    {view, _panel} = signed_in_panel(conn)

    assert has_element?(view, "#covered-call-buy-1-stock", CoveredCallsChain.stock())

    buy(view, "2")
    assert has_element?(view, "#covered-call-fill-1-review-stock", CoveredCallsChain.stock())

    {:ok, view, _html} = live(build_conn(), "/stock/covered-call?bid=1")
    settled(view)
    assert has_element?(view, "#covered-calls-sell-stock", CoveredCallsChain.stock())
    assert has_element?(view, "#covered-call-sell-1-stock", CoveredCallsChain.stock())

    {:ok, view, _html} = live(build_conn(), "/stock/covered-call?tab=bid")
    settled(view)
    assert has_element?(view, "#covered-calls-bid-stock", CoveredCallsChain.stock())
  end

  test "Sell now's receipt gives the sale's premium and fee, and a bid's minimum when it is not one token",
       %{conn: conn} do
    CoveredCallsChain.install(%{bids: [CoveredCallsChain.bid(%{min_sale: 2 * @unit})]})
    {:ok, view, _html} = live(conn, "/stock/covered-call?bid=1")
    settled(view)

    view |> element("#covered-call-sell-1-form") |> render_change(%{"amount" => "2"})
    settled(view)

    assert text(view, "#covered-call-sell-1-premium") == "$6.00"
    assert text(view, "#covered-call-sell-1-fee") == F.usd(60_000)
    assert text(view, "#covered-call-sell-1-receive") == "$5.94"
    assert text(view, "#covered-call-sell-1-minimum") == "2 AMZNc"
  end

  test "under the premium, the best open bid or the lowest listing on the ticket's own terms, with its size",
       %{conn: conn} do
    CoveredCallsChain.install(%{
      bids: [
        CoveredCallsChain.bid(%{premium: 2_000_000}),
        CoveredCallsChain.bid(%{premium: 4_000_000, amount: 7 * @unit})
      ]
    })

    {:ok, view, _html} = live(conn, "/stock/covered-call")
    settled(view)
    assert text(view, "#covered-calls-sell-live") == ""

    # The listing's and the bids' own strike, on the Friday they are all on.
    custom = fn form ->
      render_click(element(view, "#covered-calls-#{form}-strike button[data-tab=custom]"))

      render_change(element(view, "#covered-calls-#{form}-form"), %{
        "custom" => "260",
        "_target" => ["custom"]
      })

      settled(view)
    end

    custom.("sell")
    assert text(view, "#covered-calls-sell-live") =~ "$4.00"
    assert text(view, "#covered-calls-sell-live") =~ "3 AMZNc"

    {:ok, view, _html} = live(build_conn(), "/stock/covered-call?tab=bid")
    settled(view)

    render_click(element(view, "#covered-calls-bid-strike button[data-tab=custom]"))

    render_change(element(view, "#covered-calls-bid-form"), %{
      "custom" => "260",
      "_target" => ["custom"]
    })

    settled(view)
    assert text(view, "#covered-calls-bid-live") =~ "$3.00"
    assert text(view, "#covered-calls-bid-live") =~ "6 AMZNc"
  end

  test "a success toast offers View Portfolio", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    send(view.pid, {:covered_call_done, %{kind: :fill, lines: ["Calls on 1 AMZNc for $5.00"]}})

    assert has_element?(view, "#covered-call-done a[href='/portfolio']", "View portfolio")
  end

  test "the portfolio's own success toast leaves View Portfolio out", %{conn: conn} do
    CoveredCallsChain.install()
    {view, _account} = portfolio(conn)
    send(view.pid, {:covered_call_done, %{kind: :claim, lines: ["1 AMZNc"]}})
    # The page hands the toast to its section (send_update): one more render shows it.
    render(view)

    assert has_element?(view, "#portfolio-covered-calls-done")
    refute has_element?(view, "#portfolio-covered-calls-done a[href='/portfolio']")
  end

  test "the contract is named at the foot of the page with its verified code on Sourcify",
       %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    contract = CoveredCallsChain.contract()

    assert has_element?(view, "a[href='https://repo.sourcify.dev/#{Lab.chain_id()}/#{contract}']")

    assert has_element?(view, "#covered-calls-contract")
  end

  test "a listing's address that isn't for sale says so", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?listing=7")
    render_async(view)

    assert has_element?(
             view,
             ".covered-calls__note[role=status]",
             "Listing 7 isn't for sale here now"
           )
  end

  test "the Sell tab lists the open bids under the ticket, with what each still wants",
       %{conn: conn} do
    first = hd(Terms.expiries(CoveredCallsChain.now()))

    CoveredCallsChain.install(%{
      bids: [
        CoveredCallsChain.bid(%{}),
        CoveredCallsChain.bid(%{amount: 3 * @unit, filled: 3 * @unit}),
        CoveredCallsChain.bid(%{amount: 0, filled: 0}),
        CoveredCallsChain.bid(%{expiry: first - 7 * 86_400})
      ]
    })

    {:ok, view, _html} = live(conn, "/stock/covered-call")
    html = settled(view)

    assert has_element?(view, "#covered-call-bids-1", "6 AMZNc")
    assert has_element?(view, "#covered-call-bids-1 a[href='/stock/covered-call?bid=1']", "Sell")

    for id <- 2..4, do: refute(has_element?(view, "#covered-call-bids-#{id}"))

    # The listing ticket stays the first thing on Sell.
    assert position(html, "covered-calls-sell") < position(html, "covered-calls-bids-title")
  end

  test "the Sell tab's bids keep equal terms together, the best for a seller first",
       %{conn: conn} do
    first = hd(Terms.expiries(CoveredCallsChain.now()))

    CoveredCallsChain.install(%{
      bids: [
        CoveredCallsChain.bid(%{}),
        CoveredCallsChain.bid(%{
          expiry: first + 7 * 86_400,
          strike: 250_000_000,
          premium: 5_000_000
        }),
        CoveredCallsChain.bid(%{strike: 270_000_000, premium: 4_000_000}),
        CoveredCallsChain.bid(%{premium: 4_000_000}),
        CoveredCallsChain.bid(%{})
      ]
    })

    {:ok, view, _html} = live(conn, "/stock/covered-call")
    html = settled(view)

    # The soonest expiry, then the most a seller ends with at the $254 price
    # (the premium plus the strike, counted no higher than the price), then the
    # highest strike, then the oldest.
    order = Enum.sort_by(1..5, &position(html, "covered-call-bids-#{&1}"))
    assert order == [3, 4, 1, 5, 2]
  end

  test "with no open bids the Sell tab has no Bids", %{conn: conn} do
    CoveredCallsChain.install(%{bids: [CoveredCallsChain.bid(%{amount: 0, filled: 0})]})
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    settled(view)

    assert has_element?(view, "#covered-calls-sell")
    refute has_element?(view, "#covered-calls-bids-title")
  end

  test "a bid's address opens its Sell now ticket with the bid's strike on the price line",
       %{conn: conn} do
    CoveredCallsChain.install(%{bids: [CoveredCallsChain.bid(%{})]})
    put_line()
    {:ok, view, _html} = live(conn, "/stock/covered-call?bid=1")
    settled(view)

    assert has_element?(view, "#covered-calls-tabs a[data-tab=sell][aria-current=page]")
    assert has_element?(view, "#covered-call-bids-1 tr.covered-calls__chosen")
    assert has_element?(view, "#covered-call-sell-1", "Sell now")
    assert plot(view, "covered-call-sell-1-price", "data-levels") == [260.0]

    # Signed out, the receipt already counts what a sale pays: 2 AMZNc at $3
    # premium each is $6.00, less the 1% fee.
    view |> element("#covered-call-sell-1-form") |> render_change(%{"amount" => "2"})
    assert text(view, "#covered-call-sell-1-receive") == "$5.94"
    assert text(view, "#covered-call-sell-1-outcomes li:first-child span") == "$5.94"
    assert text(view, "#covered-call-sell-1-outcomes li:last-child span") == "$525.94"
    assert text(view, "#covered-call-sell-1-exercised") == "$520.00"
    assert has_element?(view, "#covered-call-sale-1 button[data-account-target=sign-in]")
  end

  test "a bid's address that isn't open says so", %{conn: conn} do
    CoveredCallsChain.install(%{bids: [CoveredCallsChain.bid(%{amount: 0, filled: 0})]})
    {:ok, view, _html} = live(conn, "/stock/covered-call?bid=1")
    settled(view)
    assert has_element?(view, ".covered-calls__note[role=status]", "Bid 1 isn't offered here now")
  end

  test "signed in, Max on Sell now fills what the bid still wants or the wallet holds, the less",
       %{conn: conn} do
    CoveredCallsChain.install(%{bids: [CoveredCallsChain.bid(%{})]})
    {view, _panel} = signed_in(conn, "/stock/covered-call?bid=1", "#covered-call-sale-1")
    assert text(view, "#covered-call-sell-1-balance") =~ "10 AMZNc"
    assert max_fill(view, "#covered-call-sell-1-max") == 6 * @unit

    CoveredCallsChain.install(%{balance: 2 * @unit, bids: [CoveredCallsChain.bid(%{})]})
    {view, _panel} = signed_in(conn, "/stock/covered-call?bid=1", "#covered-call-sale-1")
    assert max_fill(view, "#covered-call-sell-1-max") == 2 * @unit
  end

  test "Sell now's receipt and its prepared step pay the same, and its review approves the stock, then sells",
       %{conn: conn} do
    CoveredCallsChain.install(%{bids: [CoveredCallsChain.bid(%{})]})
    {view, _panel} = signed_in(conn, "/stock/covered-call?bid=1", "#covered-call-sale-1")

    view |> element("#covered-call-sell-1-form") |> render_change(%{"amount" => "2"})
    settled(view)

    assert text(view, "#covered-call-sell-1-receive") == "$5.94"
    assert has_element?(view, "#covered-call-sell-1-receipt", "Paid now")

    view |> element("#covered-call-sale-1-review") |> render_click()

    refute has_element?(view, "#covered-call-sale-1-review-panel[hidden]")
    assert has_element?(view, "#covered-call-sale-1-review-panel", "$5.94, paid now")
    assert has_element?(view, "#covered-call-sale-1-review-panel [data-step=stock_approval]")
    assert has_element?(view, "#covered-call-sale-1-review-panel [data-step=sell_to_bid]")

    assert has_element?(
             view,
             "#covered-call-sale-1 [data-onchain-step=stock_approval]",
             "Approve AMZNc"
           )
  end

  test "a sale below the bid's minimum or past what it wants is disabled with the reason",
       %{conn: conn} do
    CoveredCallsChain.install(%{bids: [CoveredCallsChain.bid(%{})]})
    {view, _panel} = signed_in(conn, "/stock/covered-call?bid=1", "#covered-call-sale-1")

    for {amount, why} <- [{"0.5", "Minimum sale 1 AMZNc"}, {"7", "More than the bid wants"}] do
      view |> element("#covered-call-sell-1-form") |> render_change(%{"amount" => amount})
      settled(view)
      assert has_element?(view, "#covered-call-sale-1-review[disabled]")
      assert has_element?(view, "#covered-call-sale-1-why", why)
    end
  end

  test "Buy's switch opens the Bid ticket at its own address, and back", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    settled(view)

    assert has_element?(view, "#covered-calls-buy-mode button[data-tab=buy][aria-pressed=true]")
    assert has_element?(view, "#covered-call-1")

    view |> element("#covered-calls-buy-mode button[data-tab=bid]") |> render_click()
    assert_patch(view, "/stock/covered-call?tab=bid")
    settled(view)

    assert has_element?(view, "#covered-calls-buy-mode button[data-tab=bid][aria-pressed=true]")
    assert has_element?(view, "#covered-calls-tabs a[data-tab=buy][aria-current=page]")
    assert has_element?(view, "#covered-calls-bid")
    refute has_element?(view, "#covered-call-1")

    view |> element("#covered-calls-buy-mode button[data-tab=buy]") |> render_click()
    assert_patch(view, "/stock/covered-call?tab=buy")
    assert has_element?(view, "#covered-call-1")
  end

  test "the Bid receipt counts what the bid holds, its exercise and break-even, with the minimum sale in its note",
       %{conn: conn} do
    CoveredCallsChain.install()
    put_line()
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=bid")
    settled(view)

    view |> element("#covered-calls-bid-strike button[data-tab=custom]") |> render_click()
    form = element(view, "#covered-calls-bid-form")
    render_change(form, %{"amount" => "0.5", "custom" => "270", "_target" => ["custom"]})
    render_change(form, %{"premium" => "4", "_target" => ["premium"]})
    settled(view)

    assert text(view, "#covered-calls-bid-pay") == "$2.00"
    assert text(view, "#covered-calls-bid-exercise") == "$135.00"
    assert text(view, "#covered-calls-bid-get") == "0.5 AMZNc"
    assert text(view, "#covered-calls-bid-break-even") == "$274.00 per AMZNc"
    assert plot(view, "covered-calls-bid-price", "data-levels") == [270.0, 274.0]

    # The page sets the minimum sale: the whole bid when it asks for less than a token.
    assert has_element?(view, "#covered-calls-bid-receipt-tip", "at least 0.5 AMZNc")
    render_change(form, %{"amount" => "3", "_target" => ["amount"]})
    assert has_element?(view, "#covered-calls-bid-receipt-tip", "at least 1 AMZNc")
    assert text(view, "#covered-calls-bid-pay") == "$12.00"
  end

  test "Place bid reviews the USDC approval, then the bid", %{conn: conn} do
    CoveredCallsChain.install()
    {view, _panel} = signed_in(conn, "/stock/covered-call?tab=bid", "#covered-call-bid")

    view
    |> element("#covered-calls-bid-form")
    |> render_change(%{"amount" => "2", "_target" => ["amount"]})

    settled(view)
    view |> element("#covered-call-bid-review") |> render_click()

    refute has_element?(view, "#covered-call-bid-review-panel[hidden]")
    assert has_element?(view, "#covered-call-bid-review-panel", "You pay")
    assert has_element?(view, "#covered-call-bid-review-panel [data-step=usdc_approval]")
    assert has_element?(view, "#covered-call-bid-review-panel [data-step=bid]")

    assert has_element?(
             view,
             "#covered-call-bid [data-onchain-step=usdc_approval]",
             "Approve USDC"
           )
  end

  test "a bid the wallet can't pay for is disabled with the reason", %{conn: conn} do
    CoveredCallsChain.install(%{usdc_balance: 1_000_000})
    {view, _panel} = signed_in(conn, "/stock/covered-call?tab=bid", "#covered-call-bid")

    view
    |> element("#covered-calls-bid-form")
    |> render_change(%{"amount" => "2", "_target" => ["amount"]})

    settled(view)
    assert has_element?(view, "#covered-call-bid-review[disabled]")
    assert has_element?(view, "#covered-call-bid-why", "Not enough USDC on Base")
  end

  test "the portfolio shows each of the wallet's bids with its parts and steps", %{conn: conn} do
    account = TestSupport.register_creator!()
    first = hd(Terms.expiries(CoveredCallsChain.now()))
    mine = &CoveredCallsChain.bid(Map.put(&1, :bidder, account.wallet_address))

    CoveredCallsChain.install(%{
      listings: [],
      bids: [
        mine.(%{filled: 0}),
        mine.(%{filled: 3 * @unit}),
        mine.(%{amount: 0, filled: 0, refund_due: 30_000_000, refundable: 30_000_000}),
        mine.(%{expiry: first - 7 * 86_400, refundable: 18_000_000}),
        mine.(%{
          amount: 2 * @unit,
          filled: 2 * @unit,
          refund_due: 24_000_000,
          refundable: 24_000_000
        }),
        CoveredCallsChain.bid(%{})
      ]
    })

    {view, _account} = portfolio(conn, account)

    # Open: nothing sold yet, the whole premium held, raised or stopped from here.
    assert has_element?(view, "#portfolio-covered-calls-bid-1", "Bidder")
    assert has_element?(view, "#portfolio-covered-calls-bid-1", "Open")
    assert has_element?(view, "#portfolio-covered-calls-bid-1-sold", "0 of 10 AMZNc")
    assert has_element?(view, "#portfolio-covered-calls-bid-1-escrow", "$30.00")

    assert has_element?(
             view,
             "#portfolio-covered-calls-bid-1-sold #portfolio-covered-calls-raise_bid-1-amount"
           )

    assert has_element?(
             view,
             "#portfolio-covered-calls-bid-1-escrow #portfolio-covered-calls-cancel_bid-1",
             "Stop"
           )

    refute has_element?(view, "#portfolio-covered-calls-bid-1-refund")

    # Partly sold: the premium left behind the rest.
    assert has_element?(view, "#portfolio-covered-calls-bid-2-sold", "3 of 10 AMZNc")
    assert has_element?(view, "#portfolio-covered-calls-bid-2-escrow", "$21.00")

    # Stopped before any sold: only the refund.
    assert has_element?(view, "#portfolio-covered-calls-bid-3", "Stopped")
    refute has_element?(view, "#portfolio-covered-calls-bid-3-sold")
    refute has_element?(view, "#portfolio-covered-calls-bid-3-escrow")

    assert has_element?(
             view,
             "#portfolio-covered-calls-bid-3-refund #portfolio-covered-calls-refund_bid-3",
             "Refund"
           )

    assert has_element?(view, "#portfolio-covered-calls-bid-3-refund", "$30.00")

    # Expired with part unsold: what was sold, and the premium never spent to refund.
    assert has_element?(view, "#portfolio-covered-calls-bid-4", "Expired")
    assert has_element?(view, "#portfolio-covered-calls-bid-4-sold", "4 of 10 AMZNc")
    assert has_element?(view, "#portfolio-covered-calls-bid-4-refund", "$18.00")
    refute has_element?(view, "#portfolio-covered-calls-raise_bid-4")
    refute has_element?(view, "#portfolio-covered-calls-cancel_bid-4")

    # Stopped after a sale: the contract closes the bid at what was sold, so
    # the row says how much was sold, with nothing left to ask for.
    assert has_element?(view, "#portfolio-covered-calls-bid-5", "Closed")
    assert text(view, "#portfolio-covered-calls-bid-5-sold span") == "2 AMZNc"
    assert has_element?(view, "#portfolio-covered-calls-bid-5-refund", "$24.00")
    refute has_element?(view, "#portfolio-covered-calls-bid-5-escrow")
    refute has_element?(view, "#portfolio-covered-calls-raise_bid-5")

    refute has_element?(view, "#portfolio-covered-calls-bid-6")
  end

  test "a listing or bid on a Friday after the year 9999 stays off Buy and Sell, and its maker can still stop it",
       %{conn: conn} do
    account = TestSupport.register_creator!()
    wallet = account.wallet_address

    # A Friday at 21:00 UTC in the year 10000, which the contract takes, and
    # the largest time it can hold.
    far = [253_402_894_800, 2 ** 64 - 1]

    CoveredCallsChain.install(%{
      listings:
        Enum.map(far, &CoveredCallsChain.listing(%{seller: wallet, expiry: &1, filled: 0})) ++
          [CoveredCallsChain.listing(%{})],
      bids:
        Enum.map(far, &CoveredCallsChain.bid(%{bidder: wallet, expiry: &1, premium: 1})) ++
          [CoveredCallsChain.bid(%{})]
    })

    {:ok, view, _html} = live(conn, "/stock/covered-call")
    render_async(view)
    assert has_element?(view, "#covered-call-bids-3")
    refute has_element?(view, "#covered-call-bids-1")
    refute has_element?(view, "#covered-call-bids-2")

    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    render_async(view)
    assert has_element?(view, "#covered-call-3")
    refute has_element?(view, "#covered-call-1")

    {view, _account} = portfolio(conn, account)

    for id <- [1, 2] do
      assert has_element?(view, "#portfolio-covered-calls-sold-#{id}-for_sale")
      assert has_element?(view, "#portfolio-covered-calls-cancel_bid-#{id}", "Stop")
    end
  end

  test "asking the panel to read the wallet again stops the read still running", %{conn: conn} do
    CoveredCallsChain.install()
    # The Sell ticket with no amount typed: the wallet's read is its panel's only one.
    {_view, panel} = signed_in_sell(conn)

    CoveredCallsChain.put(%{hold: self()})

    [first, second, last] =
      for _ask <- 1..3 do
        render_hook(panel, "refresh_funds", %{})
        assert_receive {:held, reader}
        Process.monitor(reader)
      end

    assert_receive {:DOWN, ^first, :process, _pid, _reason}
    assert_receive {:DOWN, ^second, :process, _pid, _reason}
    refute_receive {:DOWN, ^last, :process, _pid, _reason}, 100
  end

  test "a bid's Raise, Stop and Refund each review their own step", %{conn: conn} do
    account = TestSupport.register_creator!()
    mine = &CoveredCallsChain.bid(Map.put(&1, :bidder, account.wallet_address))

    CoveredCallsChain.install(%{
      listings: [],
      bids: [
        mine.(%{filled: 0}),
        mine.(%{amount: 0, filled: 0, refund_due: 30_000_000, refundable: 30_000_000})
      ]
    })

    {view, account} = portfolio(conn, account)

    for panel <- ~w(raise_bid-1 cancel_bid-1 refund_bid-2) do
      view
      |> with_target("#portfolio-covered-calls-#{panel}")
      |> render_hook("onchain_active_wallet", %{"address" => account.wallet_address})
    end

    render_async(view)

    view
    |> element("#portfolio-covered-calls-raise_bid-1-form")
    |> render_submit(%{"amount" => "2"})

    assert has_element?(view, "#portfolio-covered-calls-raise_bid-1-review-panel", "$6.00")
    assert has_element?(view, "#portfolio-covered-calls-raise_bid-1 [data-step=usdc_approval]")
    assert has_element?(view, "#portfolio-covered-calls-raise_bid-1 [data-step=raise_bid]")

    view |> element("#portfolio-covered-calls-cancel_bid-1-review") |> render_click()
    assert has_element?(view, "#portfolio-covered-calls-cancel_bid-1-review-panel", "$30.00")
    assert has_element?(view, "#portfolio-covered-calls-cancel_bid-1 [data-step=cancel_bid]")

    view |> element("#portfolio-covered-calls-refund_bid-2-review") |> render_click()
    assert has_element?(view, "#portfolio-covered-calls-refund_bid-2-review-panel", "$30.00")
    assert has_element?(view, "#portfolio-covered-calls-refund_bid-2 [data-step=refund_bid]")
  end

  # The receipt's figures against the quote for the same request, the action
  # an agent reads before listing.
  defp assert_receipt(view, request) do
    {:ok, %{receipt: receipt}} = CoveredCalls.covered_call_quote("AMZNc", request, actor: nil)

    assert text(view, "#covered-calls-sell-net") == F.usd(receipt.net_premium)
    assert text(view, "#covered-calls-sell-fee") == F.usd(receipt.fee)
    assert text(view, "#covered-calls-sell-exercised") == F.usd(receipt.strike)
  end

  # The book's read starts the quote's: both are waited for.
  defp settled(view) do
    render_async(view)
    render_async(view)
  end

  # The amount typed on the Buy ticket, then its review pressed. The page hears
  # the change before the press, so the panel reviews the amount typed.
  defp buy(view, amount) do
    view |> element("#covered-call-buy-1-form") |> render_change(%{"amount" => amount})
    view |> element("#covered-call-fill-1-review") |> render_click()
  end

  # A new signed-in person on a listing's Buy ticket, their wallet open.
  defp signed_in_panel(conn),
    do: signed_in(conn, "/stock/covered-call?listing=1", "#covered-call-fill-1")

  # A new signed-in person on the Sell ticket, their wallet open.
  defp signed_in_sell(conn), do: signed_in(conn, "/stock/covered-call", "#covered-call-list")

  # A new signed-in person at `path`, their wallet open in `panel`.
  defp signed_in(conn, path, panel) do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live(path)

    settled(view)
    panel = with_target(view, panel)
    render_hook(panel, "onchain_active_wallet", %{"address" => account.wallet_address})
    settled(view)
    {view, panel}
  end

  # What a Max button fills its box with in the browser, in raw units.
  defp max_fill(view, selector) do
    [fill] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("phx-click")
      |> Enum.flat_map(&JSON.decode!/1)

    assert ["dispatch", %{"event" => "autolaunch:fill", "detail" => %{"value" => value}}] = fill
    F.parse_tokens(value, @unit)
  end

  # The signed-in portfolio, its covered calls read.
  defp portfolio(conn, account \\ TestSupport.register_creator!()) do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/portfolio")

    render_async(view)
    {view, account}
  end

  # No line held for the market, now and once the test ends.
  defp forget_line do
    key = PriceLine.key("AMZNc")
    :ok = SharedReading.delete(key)
    on_exit(fn -> SharedReading.delete(key) end)
  end

  # The market's last 30 days as the reader holds them: from $250 to $254.
  defp put_line do
    now = CoveredCallsChain.now()

    :ok =
      SharedReading.put(PriceLine.key("AMZNc"), %{
        decimals: 8,
        points: [{now - 20 * 86_400, 25_000_000_000}, {now, 25_400_000_000}]
      })
  end

  # A price line's plot attribute, decoded.
  defp plot(view, id, name), do: view |> attribute("##{id}-plot", name) |> JSON.decode!()

  # A suggested strike's price in dollars, as its pill carries it.
  defp pill_strike(view, choice) do
    {price, ""} =
      view
      |> attribute("#covered-calls-sell-strike button[data-tab='#{choice}']", "data-strike")
      |> Float.parse()

    price
  end

  defp attribute(view, selector, name) do
    [value] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute(name)

    value
  end

  defp text(view, selector), do: view |> element(selector) |> render() |> words()

  defp iso(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp position(html, id) do
    {at, _length} = :binary.match(html, ~s(id="#{id}"))
    at
  end

  # A page's visible words, tags dropped and spaces made single.
  defp words(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
end
