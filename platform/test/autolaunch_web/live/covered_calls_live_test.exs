defmodule AutolaunchWeb.CoveredCallsLiveTest do
  @moduledoc """
  `/covered-calls` shows what the contract holds: the Buy tab lists only the
  calls still for sale with the amount left, a listing's panel opens from its
  own address, the Sell tab carries the terms and the guide, and with covered
  calls switched off the address is not found and the stock page offers nothing.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{CoveredCallsChain, TestSupport}
  alias AutolaunchWeb.OnchainSteps

  @unit CoveredCallsChain.unit()

  test "switched off, the page is not found and the stock page offers no covered calls",
       %{conn: conn} do
    {404, _headers, _body} = assert_error_sent(404, fn -> get(conn, "/covered-calls") end)
    refute conn |> get("/stock-listing/AMZNc") |> html_response(200) =~ "Covered calls on"
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

    {:ok, view, _html} = live(conn, "/covered-calls")
    html = render_async(view)

    assert has_element?(view, "#covered-call-1")
    refute has_element?(view, "#covered-call-2")
    refute has_element?(view, "#covered-call-3")
    assert html =~ "$260.00"
    assert html =~ "6 AMZNc"

    assert conn |> get("/stock-listing/AMZNc") |> html_response(200) =~ "Covered calls on AMZNc"
  end

  test "who may use covered calls is said once, under the page title, and nowhere else",
       %{conn: conn} do
    CoveredCallsChain.install()
    line = "Available to eligible people outside the US."
    {:ok, view, _html} = live(conn, "/covered-calls")
    html = render_async(view)

    assert view |> element("h1 + #covered-calls-eligibility") |> render() =~ line
    assert html |> String.split(line) |> length() == 2

    for path <- ["/", "/stock-listing/AMZNc", "/docs", "/llms-full.txt"],
        do: refute(conn |> get(path) |> response(200) =~ line)
  end

  test "a listing's panel opens from its address with its amount left to buy", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/covered-calls?listing=1")
    render_async(view)

    assert has_element?(view, "#covered-call-fill-1 input[name=amount][value='6']")
    assert has_element?(view, "#covered-call-fill-1 [data-onchain-step=usdc_approval]")
    assert has_element?(view, "#covered-call-fill-1 [data-onchain-step=fill]")
  end

  test "with nothing for sale the Buy tab says so", %{conn: conn} do
    CoveredCallsChain.install(%{listings: []})
    {:ok, view, _html} = live(conn, "/covered-calls")
    assert render_async(view) =~ "No calls for sale right now"
  end

  test "the Sell tab offers the next four Fridays and states the terms", %{conn: conn} do
    CoveredCallsChain.install()
    {:ok, view, _html} = live(conn, "/covered-calls?tab=sell")
    html = render_async(view)

    expiries = Autolaunch.CoveredCalls.Terms.expiries(CoveredCallsChain.now())

    for expiry <- expiries,
        do: assert(has_element?(view, "select[name=expiry] option[value='#{expiry}']"))

    assert html =~ "Dividends during the week stay with the tokens."
    assert html =~ "$254.00"
    assert html =~ "Suggested premiums"
  end

  test "a stale reference price hides the suggestion and keeps the form", %{conn: conn} do
    CoveredCallsChain.install(%{price: 0})
    {:ok, view, _html} = live(conn, "/covered-calls?tab=sell")
    html = render_async(view)

    refute html =~ "Suggested premiums"
    assert has_element?(view, "#covered-call-list [data-onchain-step=list]")
  end

  # A press the panel can't build steps for says so, and the page's follow-up keeps the words:
  # it never silently does nothing (the portfolio's buttons are these same panels).
  test "a press the chain can't be read for says nothing was sent", %{conn: conn} do
    assert_unsent(conn, %{unreadable: true}, "1")
  end

  test "a press with an amount that doesn't read says nothing was sent", %{conn: conn} do
    assert_unsent(conn, %{}, "lots")
  end

  defp assert_unsent(conn, chain, amount) do
    note = "#covered-call-fill-1 [role=status]"
    CoveredCallsChain.install()
    {view, panel} = signed_in_panel(conn)
    CoveredCallsChain.put(chain)
    refute has_element?(view, note, OnchainSteps.unsent_note())

    render_hook(panel, "prepare_and_send", %{"form" => %{"amount" => amount}, "step" => "fill"})
    assert_reply(view, reply)
    assert reply == %{}
    assert has_element?(view, note, OnchainSteps.unsent_note())

    render_hook(panel, "step_failed", %{"step" => "fill", "reason" => "step_unknown"})
    assert has_element?(view, note, OnchainSteps.unsent_note())
  end

  # A new signed-in person on a listing's Buy panel, their wallet open.
  defp signed_in_panel(conn) do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/covered-calls?listing=1")

    render_async(view)
    panel = with_target(view, "#covered-call-fill-1")
    render_hook(panel, "onchain_active_wallet", %{"address" => account.wallet_address})
    render_async(view)
    {view, panel}
  end
end
