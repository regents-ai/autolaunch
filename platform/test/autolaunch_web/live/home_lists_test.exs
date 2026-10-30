defmodule AutolaunchWeb.HomeListsTest do
  @moduledoc """
  The home page opens on its products, each card linking to its own page, then
  one list chosen from Auctions, Tokens and Options. Tokens choose a type: All,
  Memestock, Revstake or Isolated, the After-hours tokens read from Base. A
  product switched off on the site has no card and no choice.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{CoveredCallsChain, ExposureChain, TestSupport}

  # Reads run as async tasks; a loaded machine can take longer than LiveViewTest's 100 ms.
  @async_ms 2_000

  test "with every product on, the four cards each link to their page", %{conn: conn} do
    CoveredCallsChain.install()
    ExposureChain.install()
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
    {:ok, view, _html} = live(conn, "/")

    for {id, title, path} <- [
          {"calls", "Call Option Onchain", "/covered-calls"},
          {"after-hours", "Isolated After-hours Exposure", "/after-hour-stocks"},
          {"memestock", "Memestock Pair", "/create"},
          {"revstake", "Revenue Share Token", "/create/revstake"}
        ] do
      assert has_element?(view, "#home-product-#{id}-title[aria-expanded=false]", title)
      assert has_element?(view, "#home-product-#{id}-more a[href='#{path}']")
    end

    assert has_element?(view, "#home-lists a[data-tab=options][href='/?view=options']")
    assert has_element?(view, "#home-lists a[data-tab=auctions][aria-current=page]")
  end

  test "before launches open, the launch cards keep their button, switched off", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    for id <- ~w(memestock revstake) do
      assert has_element?(view, "#home-product-#{id}-more button[disabled]", "Launch one")
      assert has_element?(view, "#home-product-#{id}-more", "Opens soon")
      refute has_element?(view, "#home-product-#{id}-more a")
    end
  end

  test "with covered calls and Exposure off, neither has a card or a choice", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?view=tokens")

    refute has_element?(view, "#home-product-calls")
    refute has_element?(view, "#home-product-after-hours")
    assert has_element?(view, "#home-product-memestock")
    refute has_element?(view, "#home-lists a[data-tab=options]")
    refute has_element?(view, "#home-kinds a[data-tab=isolated]")

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
  end

  test "Options with nothing for sale says so and offers selling", %{conn: conn} do
    CoveredCallsChain.install(%{listings: []})
    {:ok, view, _html} = live(conn, "/?view=options")
    render_async(view, @async_ms)

    assert has_element?(view, "#home-calls h2", "No calls for sale")
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

  test "Isolated lists both tokens of each series, each opening its series", %{conn: conn} do
    ExposureChain.install()
    {:ok, view, _html} = live(conn, "/?kind=isolated&view=tokens")
    render_async(view, @async_ms)

    series = "/after-hour-stocks?series=#{ExposureChain.series()}"
    overnight = view |> element("#home-isolated-#{ExposureChain.overnight()}") |> render()
    session = view |> element("#home-isolated-#{ExposureChain.session()}") |> render()

    assert has_element?(view, "#home-kinds a[data-tab=isolated][aria-current=page]")
    assert overnight =~ "AMZNc After-hours to 6 Nov 2026"
    assert overnight =~ series
    # 2.64 USDC each, 0.1 in circulation.
    assert overnight =~ "$2.64"
    assert overnight =~ "$0.26"
    assert session =~ "$2.51"
    refute has_element?(view, "#home-market")
  end

  test "All tokens puts the running series' tokens above the launched ones", %{conn: conn} do
    ExposureChain.install()

    auction =
      TestSupport.project_auction(
        chain_id: 8453,
        symbol: "LNCH",
        state: :graduated,
        token_address: "0x3333333333333333333333333333333333333333"
      )

    TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    {:ok, view, _html} = live(conn, "/?view=tokens")
    render_async(view, @async_ms)

    assert has_element?(view, "#home-kinds a[data-tab=all][aria-current=page]")
    assert has_element?(view, "#home-isolated-#{ExposureChain.overnight()}")
    assert has_element?(view, "#home-market", "LNCH")
    assert has_element?(view, ".home-result-count", "Showing 3 tokens")

    # Robinhood holds no After-hours tokens, and a search keeps only those it names.
    {:ok, view, _html} = live(conn, "/?view=tokens&chain=robinhood")
    render_async(view, @async_ms)
    refute has_element?(view, "#home-isolated-#{ExposureChain.overnight()}")

    {:ok, view, _html} = live(conn, "/?view=tokens&q=market-hours")
    render_async(view, @async_ms)
    refute has_element?(view, "#home-isolated-#{ExposureChain.overnight()}")
    assert has_element?(view, "#home-isolated-#{ExposureChain.session()}")

    # An ended series stays under Isolated only.
    ExposureChain.put(%{status: 2, end_reason: 1})
    {:ok, view, _html} = live(conn, "/?view=tokens")
    render_async(view, @async_ms)
    refute has_element?(view, "#home-isolated-#{ExposureChain.overnight()}")
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
