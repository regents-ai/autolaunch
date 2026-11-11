defmodule AutolaunchWeb.CoveredCallsLiveTest do
  @moduledoc """
  `/stock/covered-call` shows what the contract holds: the Buy tab lists only the
  calls still for sale with the amount left, a listing's ticket opens from its
  own address, the Sell ticket's receipt is the quote's for the ticket as it
  stands, and with covered calls switched off the address is not found and the
  stock page offers nothing. The portfolio lists each listing's parts, each
  with its own step.

  A panel works as the token page's Stake does: its button reviews the ticket as
  it stands and opens the wallet steps over it, one wallet button at a time;
  the button is disabled only when the chain makes the action certain to fail.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{CoveredCalls, CoveredCallsChain, SharedReading, TestSupport}
  alias Autolaunch.CoveredCalls.{PriceLine, Terms}
  alias AutolaunchWeb.CoveredCallsFormat, as: F

  @unit CoveredCallsChain.unit()
  # Reads run as async tasks; a loaded machine can take longer than LiveViewTest's 100 ms.
  @async_ms 2_000

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
    html = render_async(view, @async_ms)

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
    html = render_async(view, @async_ms)
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
    render_async(view, @async_ms)

    assert has_element?(view, "#covered-call-buy-1-amount[value='6']")
    assert has_element?(view, "#covered-call-fill-1 button[data-account-target=sign-in]")
  end

  test "with nothing for sale the Buy tab says so", %{conn: conn} do
    CoveredCallsChain.install(%{listings: []})
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    assert render_async(view, @async_ms) =~ "No listings"
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

  test "under You receive, the quote's share of the stock's worth and its term", %{conn: conn} do
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

    [percent, days] =
      Regex.run(~r/([\d.]+)%\D+(\d+)/, text(view, "#covered-calls-sell-yield"),
        capture: :all_but_first
      )

    assert_in_delta String.to_float(percent), quote.receipt.net_premium_yield * 100, 0.005
    assert String.to_integer(days) == quote.term_days
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
    render_async(view, @async_ms)

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
    render_async(view, @async_ms)

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
    assert has_element?(view, "#covered-call-fill-1-review-panel", "Premium")
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

  test "a purchase the wallet can't pay for is disabled with the reason", %{conn: conn} do
    CoveredCallsChain.install(%{usdc_balance: 1_000_000})
    {view, _panel} = signed_in_panel(conn)

    view |> element("#covered-call-buy-1-form") |> render_change(%{"amount" => "2"})
    render_async(view, @async_ms)

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
    assert has_element?(view, "#covered-call-fill-1-notice", "Base couldn't be read just now.")
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

    render_async(view, @async_ms)

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

  test "in the window a seller's exercised part and the stock coming back each have their step",
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

    assert has_element?(view, "#portfolio-covered-calls-sold-1-to_collect", "3 AMZNc")

    assert has_element?(
             view,
             "#portfolio-covered-calls-sold-1-to_collect #portfolio-covered-calls-claim-1"
           )

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
    assert has_element?(view, "#portfolio-covered-calls-sold-1-to_collect", "4 AMZNc")
  end

  test "a success toast offers View Portfolio", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    send(view.pid, {:covered_call_done, %{kind: :fill, lines: ["1 AMZNc of calls for $5.00"]}})

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

  test "the contract is named at the foot of the page with its verified code on Basescan",
       %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    contract = CoveredCallsChain.contract()

    assert has_element?(
             view,
             "a[href='https://basescan.org/address/#{contract}#code']",
             "Verified on Basescan"
           )

    assert has_element?(view, "#covered-calls-contract")
  end

  test "a listing's address that isn't for sale says so", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?listing=7")
    render_async(view, @async_ms)
    assert has_element?(view, ".covered-calls__note[role=status]", "Listing 7 isn't for sale now")
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
    render_async(view, @async_ms)
    render_async(view, @async_ms)
  end

  # The amount typed on the Buy ticket, then its review pressed. The page hears
  # the change before the press, so the panel reviews the amount typed.
  defp buy(view, amount) do
    view |> element("#covered-call-buy-1-form") |> render_change(%{"amount" => amount})
    view |> element("#covered-call-fill-1-review") |> render_click()
  end

  # A new signed-in person on a listing's Buy ticket, their wallet open.
  defp signed_in_panel(conn) do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/stock/covered-call?listing=1")

    render_async(view, @async_ms)
    panel = with_target(view, "#covered-call-fill-1")
    render_hook(panel, "onchain_active_wallet", %{"address" => account.wallet_address})
    render_async(view, @async_ms)
    {view, panel}
  end

  # A new signed-in person on the Sell ticket, their wallet open.
  defp signed_in_sell(conn) do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/stock/covered-call")

    settled(view)
    panel = with_target(view, "#covered-call-list")
    render_hook(panel, "onchain_active_wallet", %{"address" => account.wallet_address})
    settled(view)
    {view, panel}
  end

  # The signed-in portfolio, its covered calls read.
  defp portfolio(conn, account \\ TestSupport.register_creator!()) do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/portfolio")

    render_async(view, @async_ms)
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
