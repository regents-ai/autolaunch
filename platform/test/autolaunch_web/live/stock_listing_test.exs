defmodule AutolaunchWeb.StockListingTest do
  @moduledoc """
  The stock listing is a short list whose every stock opens its own page with
  its details; each of those pages answers and is in the sitemap, and a
  symbol the listing does not hold is the not-found page. Above it, the stock
  products' cards, each linking to its page.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.CoveredCallsChain
  alias Autolaunch.Stocks.UpcomingCatalog

  test "the stock products' cards come first, Memestock then covered calls", %{conn: conn} do
    CoveredCallsChain.install()
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
    {:ok, view, html} = live(conn, "/stocks")

    for {id, title, path} <- [
          {"memestock", "Memestock", "/create"},
          {"calls", "Covered calls", "/stock/covered-call"}
        ] do
      assert has_element?(view, "#home-product-#{id} a[href='#{path}'] h2", title)
    end

    refute has_element?(view, "#home-product-revstake")

    assert Regex.scan(~r/id="home-product-([a-z]+)"/, html, capture: :all_but_first) ==
             [["memestock"], ["calls"]]
  end

  test "every listed stock opens its own page, which the sitemap lists", %{conn: conn} do
    listing = conn |> get("/stocks") |> html_response(200)
    sitemap = conn |> get("/sitemap.xml") |> response(200)

    links =
      ~r{href="(/stocks/[^"]+)"}
      |> Regex.scan(listing, capture: :all_but_first)
      |> List.flatten()

    assert length(links) == length(UpcomingCatalog.stocks())

    for path <- links do
      assert sitemap =~ path
      assert conn |> get(path) |> html_response(200) =~ "Chainlink feed address"
    end

    # The list carries the stocks, not their details.
    refute listing =~ "Chainlink feed address"
  end

  test "a stock's page gives its token's own address, whole, to open and copy", %{conn: conn} do
    for %{"token_address" => address} = stock when is_binary(address) <-
          UpcomingCatalog.stocks() do
      {:ok, view, _html} = live(conn, "/stocks/#{stock["symbol"]}")

      assert view |> element("#stock-token-full") |> render() =~ address
      assert has_element?(view, "#stock-token-copy")
    end
  end

  test "a symbol is read in any case, and one the listing does not hold is not found",
       %{conn: conn} do
    assert conn |> get("/stocks/aaplc") |> html_response(200) =~ "Apple Inc."

    {404, _headers, _body} =
      assert_error_sent(404, fn -> get(conn, "/stocks/NOTASTOCK") end)
  end

  test "stock Markdown uses the same catalog and keeps its dated pool observations", %{conn: conn} do
    {stock, _chain} = UpcomingCatalog.stock("AAPLc")
    conn = conn |> put_req_header("accept", "text/markdown") |> get("/stocks/AAPLc")
    markdown = response(conn, 200)
    assert markdown =~ "Token issuer: Coinbase"
    assert markdown =~ stock["token_address"]
    assert markdown =~ "Observed liquidity:"
    assert markdown =~ hd(stock["pools"])["observed_at"]
    assert Enum.any?(get_resp_header(conn, "vary"), &String.contains?(&1, "Accept"))
  end

  test "stock filters are shareable and retain the published availability groups", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/stocks")

    view |> form("#stock-directory-filters", %{"q" => "apple"}) |> render_submit()
    assert_patch(view, "/stocks?q=apple")

    assert has_element?(
             view,
             "[aria-labelledby=upcoming-available-base] a[href^='/stocks/AAPLc?']"
           )

    assert has_element?(
             view,
             "[aria-labelledby=upcoming-available-robinhood] a[aria-label='AAPL on Robinhood: stock details']"
           )

    render_patch(view, "/stocks?q=apple&chain=base&availability=available")

    assert has_element?(
             view,
             "[aria-labelledby=upcoming-available-base] a[href^='/stocks/AAPLc?']"
           )

    refute has_element?(view, "a[aria-label='AAPL on Robinhood: stock details']")
    refute has_element?(view, "#upcoming-feed-required")
    refute has_element?(view, "#upcoming-eligible")
    refute has_element?(view, "#upcoming-available-robinhood")

    render_patch(view, "/stocks?q=ASML&chain=robinhood")

    assert has_element?(
             view,
             "[aria-labelledby=upcoming-eligible-robinhood] a[href^='/stocks/ASML?']"
           )

    refute has_element?(view, "#upcoming-available a[href^='/stocks/ASML?']")

    render_patch(view, "/stocks?q=unlisted-example")
    assert has_element?(view, "#stock-directory-count", "No stocks match")
    view |> element("#stock-directory-filters a", "Reset") |> render_click()
    assert_patch(view, "/stocks")

    assert has_element?(
             view,
             "[aria-labelledby=upcoming-available-robinhood] a[aria-label='AAPL on Robinhood: stock details']"
           )

    assert has_element?(view, "#upcoming-feed-required")
  end

  test "a token address finds the stock detail without changing its network", %{conn: conn} do
    {stock, _chain} = UpcomingCatalog.stock("AAPLc")
    {:ok, view, _html} = live(conn, "/stocks?q=#{stock["token_address"]}")

    assert has_element?(view, "#stock-directory-count", "1 stock")

    assert has_element?(
             view,
             "[aria-labelledby=upcoming-available-base] a[href^='/stocks/AAPLc?']"
           )

    refute has_element?(view, "a[aria-label='AAPL on Robinhood: stock details']")
  end
end
