defmodule AutolaunchWeb.HomeListsTest do
  @moduledoc """
  The home page opens on its products, each card linking to its own page, then
  one list chosen from Auctions, Tokens and Options. Tokens choose a type: All,
  Memestock or Revstake. A product switched off on the site has no card and no
  choice.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{CoveredCallsChain, ExposureChain, TestSupport}

  # Reads run as async tasks; a loaded machine can take longer than LiveViewTest's 100 ms.
  @async_ms 2_000

  test "with every product on, the three cards each link to their page", %{conn: conn} do
    CoveredCallsChain.install()
    ExposureChain.install()
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
    {:ok, view, _html} = live(conn, "/")

    for {id, title, path} <- [
          {"calls", "Call Options", "/covered-calls"},
          {"memestock", "Memestock", "/create"},
          {"revstake", "Revstake", "/agent-business"}
        ] do
      assert has_element?(view, "#home-product-#{id} a[href='#{path}'] h2", title)
    end

    assert has_element?(view, "#home-lists a[data-tab=options][href='/?view=options']")
    assert has_element?(view, "#home-lists a[data-tab=auctions][aria-current=page]")
  end

  test "before launches open, the launch cards keep their place, not a link", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    for id <- ~w(memestock revstake) do
      assert has_element?(view, "#home-product-#{id}", "Opens soon")
      refute has_element?(view, "#home-product-#{id} a")
    end
  end

  test "with covered calls off, it has no card or choice", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?view=tokens")

    refute has_element?(view, "#home-product-calls")
    assert has_element?(view, "#home-product-memestock")
    refute has_element?(view, "#home-lists a[data-tab=options]")

    # An Options address on a site without them shows the auctions.
    {:ok, view, _html} = live(conn, "/?view=options")
    assert has_element?(view, "#home-lists a[data-tab=auctions][aria-current=page]")
    assert has_element?(view, "#home-market")
  end

  test "Options lists the calls still for sale, each opening its Buy panel", %{conn: conn} do
    expiry = hd(Autolaunch.CoveredCalls.Terms.expiries(CoveredCallsChain.now()))
    unit = CoveredCallsChain.unit()

    CoveredCallsChain.install(%{
      listings: [
        CoveredCallsChain.listing(%{amount: 10 * unit, filled: 4 * unit, strike: 260_000_000}),
        CoveredCallsChain.listing(%{amount: 3 * unit, filled: 3 * unit}),
        CoveredCallsChain.listing(%{expiry: expiry - 7 * 86_400})
      ]
    })

    {:ok, view, _html} = live(conn, "/?view=options")
    html = render_async(view, @async_ms)

    assert has_element?(view, "#home-lists a[data-tab=options][aria-current=page]")
    assert has_element?(view, "#home-call-1 a[href='/covered-calls?listing=1']", "Buy")
    refute has_element?(view, "#home-call-2")
    refute has_element?(view, "#home-call-3")
    assert html =~ "Strike $260.00"
    assert html =~ "6 AMZNc"
    refute has_element?(view, "#home-market")
    assert view |> element("#home-filters") |> render() =~ "hidden"

    # A reader that runs no scripts gets the calls in the page as it is sent.
    assert conn |> get("/?view=options") |> html_response(200) =~ "Strike $260.00"
  end

  test "Options with nothing for sale says so and offers selling", %{conn: conn} do
    CoveredCallsChain.install(%{listings: []})
    {:ok, view, _html} = live(conn, "/?view=options")
    render_async(view, @async_ms)

    assert has_element?(view, "#home-calls h2", "No listings")
    assert has_element?(view, "#home-calls a[href='/covered-calls']", "Sell calls")
  end

  test "Options that cannot be read say so and read again on Try again", %{conn: conn} do
    CoveredCallsChain.install(%{unreadable: true})
    {:ok, view, _html} = live(conn, "/?view=options")
    render_async(view, @async_ms)
    assert has_element?(view, "#home-calls", "Calls can't be shown right now.")

    CoveredCallsChain.put(%{unreadable: false})
    view |> element("#home-calls button", "Try again") |> render_click()
    render_async(view, @async_ms)
    assert has_element?(view, "#home-call-1")
  end

  test "the auctions' status is chosen in the filter menu", %{conn: conn} do
    TestSupport.project_auction(chain_id: 8453, title: "Taking Bids", state: :active)
    TestSupport.project_auction(chain_id: 8453, title: "Done Before", state: :graduated)
    {:ok, view, _html} = live(conn, "/")

    view |> element("#home-filters a", "Live") |> render_click()
    assert_patch(view, "/?sort=ending&state=active")
    render_async(view, @async_ms)
    assert has_element?(view, "#home-market", "Taking Bids")
    refute has_element?(view, "#home-market", "Done Before")
    assert has_element?(view, "#home-filters .home-filter__active")

    view |> element("#home-lists a", "Tokens") |> render_click()
    assert_patch(view, "/?view=tokens")
    refute has_element?(view, "#home-filters [aria-label=Status]")
  end
end
