defmodule AutolaunchWeb.CoveredCallsLiveTest do
  @moduledoc """
  `/stock/covered-call` shows what the contract holds: the Buy tab lists only the
  calls still for sale with the amount left, a listing's panel opens from its
  own address, the Sell tab carries the terms and the guide, and with covered
  calls switched off the address is not found and the stock page offers nothing.

  A panel works as the token page's Stake does: its button reviews the form as
  it stands and opens the wallet steps over it, one wallet button at a time;
  the button is disabled only when the chain makes the action certain to fail.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{CoveredCallsChain, TestSupport}
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
    expiry = hd(Autolaunch.CoveredCalls.Terms.expiries(CoveredCallsChain.now()))

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

  test "a listing's panel opens from its address with its amount left to buy", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?listing=1")
    render_async(view, @async_ms)

    assert has_element?(view, "#covered-call-fill-1 input[name=amount][value='6']")
    assert has_element?(view, "#covered-call-fill-1 button[data-account-target=sign-in]")
  end

  test "with nothing for sale the Buy tab says so", %{conn: conn} do
    CoveredCallsChain.install(%{listings: []})
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    assert render_async(view, @async_ms) =~ "No calls for sale right now"
  end

  test "the Sell tab offers the next four Fridays and states the terms", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    html = render_async(view, @async_ms)

    expiries = Autolaunch.CoveredCalls.Terms.expiries(CoveredCallsChain.now())

    for expiry <- expiries,
        do: assert(has_element?(view, "select[name=expiry] option[value='#{expiry}']"))

    assert html =~ "Dividends during the week stay with the tokens"
    assert html =~ "$254.00"
    assert html =~ "Suggested premiums"
  end

  test "a stale reference price hides the suggestion and keeps the form", %{conn: conn} do
    CoveredCallsChain.install(%{price: 0})
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    html = render_async(view, @async_ms)

    refute html =~ "Suggested premiums"
    assert has_element?(view, "#covered-call-list button[data-account-target=sign-in]")
  end

  test "Buy calls reviews the amount as typed: the USDC approval, then the purchase",
       %{conn: conn} do
    CoveredCallsChain.install()
    {view, _panel} = signed_in_panel(conn)

    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")

    view
    |> element("#covered-call-fill-1-form")
    |> render_submit(%{"amount" => "2"})

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

    view |> element("#covered-call-fill-1-form") |> render_submit(%{"amount" => "1"})

    assert has_element?(view, "#covered-call-fill-1 [data-step=usdc_approval][data-state=done]")
    assert has_element?(view, "#covered-call-fill-1 [data-onchain-step=fill]", "Confirm purchase")
  end

  test "a purchase the wallet can't pay for is disabled with the reason, and nothing opens",
       %{conn: conn} do
    CoveredCallsChain.install(%{usdc_balance: 1_000_000})
    {view, _panel} = signed_in_panel(conn)

    view |> element("#covered-call-fill-1-form") |> render_change(%{"amount" => "2"})
    render_async(view, @async_ms)

    assert has_element?(view, "#covered-call-fill-1-review[disabled]")
    assert has_element?(view, "#covered-call-fill-1-why", "Not enough USDC on Base")

    view |> element("#covered-call-fill-1-form") |> render_submit(%{"amount" => "2"})
    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")
    assert has_element?(view, "#covered-call-fill-1-notice", "Not enough USDC on Base.")
  end

  # A review that can't be built says so and opens nothing; it never silently does nothing.
  test "a review the chain can't be read for says so and opens nothing", %{conn: conn} do
    CoveredCallsChain.install()
    {view, _panel} = signed_in_panel(conn)
    CoveredCallsChain.put(%{unreadable: true})

    view |> element("#covered-call-fill-1-form") |> render_submit(%{"amount" => "1"})

    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")
    assert has_element?(view, "#covered-call-fill-1-notice", "Base couldn't be read just now.")
  end

  test "an amount that doesn't read asks for one and opens nothing", %{conn: conn} do
    CoveredCallsChain.install()
    {view, _panel} = signed_in_panel(conn)

    view |> element("#covered-call-fill-1-form") |> render_submit(%{"amount" => "lots"})

    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")
    assert has_element?(view, "#covered-call-fill-1-notice", "Enter an amount above zero")
  end

  test "a holder's portfolio shows Exercise before the window opens, disabled with when it opens",
       %{conn: conn} do
    CoveredCallsChain.install()
    CoveredCallsChain.put(%{held: 2 * @unit})
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/portfolio")

    render_async(view, @async_ms)

    for panel <- ["#portfolio-covered-calls-exercise-1", "#portfolio-covered-calls-claim-1"] do
      view
      |> with_target(panel)
      |> render_hook("onchain_active_wallet", %{"address" => account.wallet_address})
    end

    render_async(view, @async_ms)

    assert has_element?(view, "#portfolio-covered-calls-exercise-1-review[disabled]")
    assert has_element?(view, "#portfolio-covered-calls-exercise-1-why", "Opens Fri")
    assert has_element?(view, "#portfolio-covered-calls-claim-1-review[disabled]")
    assert has_element?(view, "#portfolio-covered-calls-claim-1-why", "Nothing to collect yet")
  end

  test "a holder's lapsed calls stay listed on the portfolio with nothing left to press",
       %{conn: conn} do
    CoveredCallsChain.install()
    lapsed = hd(Autolaunch.CoveredCalls.Terms.expiries(CoveredCallsChain.now())) - 14 * 86_400

    CoveredCallsChain.put(%{
      listings: [CoveredCallsChain.listing(%{expiry: lapsed})],
      held: 2 * @unit
    })

    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/portfolio")

    render_async(view, @async_ms)

    assert has_element?(view, "#portfolio-covered-calls-held-1", "Closed")
    refute has_element?(view, "#portfolio-covered-calls-exercise-1")
    refute has_element?(view, "#portfolio-covered-calls-claim-1")
  end

  test "the guide follows the List form: the window chosen, the strike and premium typed", %{
    conn: conn
  } do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    render_async(view, @async_ms)
    [first, second | _later] = Autolaunch.CoveredCalls.Terms.expiries(CoveredCallsChain.now())

    assert has_element?(view, "#covered-calls-outcome h3", "Example")
    assert has_element?(view, "#covered-calls-suggestions h3", F.window_days(first))

    view
    |> element("#covered-call-list-form")
    |> render_change(%{
      "amount" => "2",
      "strike" => "260",
      "premium" => "3",
      "expiry" => "#{second}"
    })

    assert has_element?(view, "#covered-calls-outcome h3", "Your trade")
    assert has_element?(view, "#covered-calls-outcome", "$260.00 strike · $3.00 premium")

    assert has_element?(view, "#covered-calls-suggestions h3", F.window_days(second))

    # Away to Buy and back, the form is built anew, and the guide starts from it again.
    view |> element(".covered-calls__tabs a", "Buy calls") |> render_click()
    view |> element(".covered-calls__tabs a", "Sell calls") |> render_click()
    assert has_element?(view, "#covered-calls-outcome h3", "Example")
    assert has_element?(view, "#covered-calls-suggestions h3", F.window_days(first))
  end

  test "a suggested strike and premium fill the List form when chosen", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    render_async(view, @async_ms)

    button = element(view, "#covered-calls-suggestions tbody tr:first-child button")

    [strike, premium] =
      for name <- ~w(strike premium), do: render(button) |> attribute("phx-value-#{name}")

    render_click(button)

    assert has_element?(view, "#covered-call-list-strike[value='#{strike}']")
    assert has_element?(view, "#covered-call-list-premium[value='#{premium}']")
    assert has_element?(view, "#covered-calls-outcome h3", "Your trade")
  end

  test "selling comes first and opens by default; Buy says how many calls are for sale",
       %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call")
    render_async(view, @async_ms)

    assert has_element?(
             view,
             ".covered-calls__tabs a:first-child[aria-current=page]",
             "Sell calls"
           )

    assert has_element?(view, "#covered-call-list-form")

    assert has_element?(
             view,
             ".covered-calls__tabs a[href='/stock/covered-call?tab=buy']",
             "Buy calls (1)"
           )
  end

  test "the market's figures are drawn from the first render, dashes until the market is read",
       %{conn: conn} do
    CoveredCallsChain.install(%{listings: []})
    {:ok, view, html} = live(conn, "/stock/covered-call")

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query("#covered-calls-summary dd")
           |> LazyHTML.text() =~ "—"

    render_async(view, @async_ms)

    assert has_element?(view, "#covered-calls-summary", "0 AMZNc")
    assert has_element?(view, "#covered-calls-summary", "0 listings")
  end

  test "a success toast offers View Portfolio", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    send(view.pid, {:covered_call_done, %{kind: :fill, lines: ["1 AMZNc of calls for $5.00"]}})

    assert has_element?(view, "#covered-call-done a[href='/portfolio']", "View Portfolio")
  end

  test "the portfolio's own success toast leaves View Portfolio out", %{conn: conn} do
    CoveredCallsChain.install()
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/portfolio")

    render_async(view, @async_ms)
    send(view.pid, {:covered_call_done, %{kind: :claim, lines: ["1 AMZNc"]}})
    # The page hands the toast to its section (send_update): one more render shows it.
    render(view)

    assert has_element?(view, "#portfolio-covered-calls-done")
    refute has_element?(view, "#portfolio-covered-calls-done a[href='/portfolio']")
  end

  test "the steps follow the tab: a buyer's on Buy, a seller's on Sell", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/stock/covered-call?tab=buy")
    render_async(view, @async_ms)
    assert has_element?(view, ".covered-calls__steps", "Exercise")
    refute has_element?(view, ".covered-calls__steps", "Settle")

    view |> element(".covered-calls__tabs a", "Sell calls") |> render_click()
    assert has_element?(view, ".covered-calls__steps", "Settle")
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

  # A new signed-in person on a listing's Buy panel, their wallet open.
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

  defp attribute(html, name) do
    [value] = html |> LazyHTML.from_fragment() |> LazyHTML.attribute(name)
    value
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
