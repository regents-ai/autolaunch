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
end
