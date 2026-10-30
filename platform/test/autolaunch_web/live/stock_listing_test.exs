defmodule AutolaunchWeb.StockListingTest do
  @moduledoc """
  The stock listing is a short list whose every stock opens its own page with
  its details; each of those pages answers and is in the sitemap, and a
  symbol the listing does not hold is the not-found page. Above it, the stock
  products' cards stand open, each with its details and its link.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{CoveredCallsChain, ExposureChain}
  alias Autolaunch.Stocks.UpcomingCatalog

  test "the three stock products stand open, each with its details and its link",
       %{conn: conn} do
    CoveredCallsChain.install()
    ExposureChain.install()
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)
    {:ok, view, _html} = live(conn, "/stocks")

    for {id, title, path} <- [
          {"memestock", "Memestock Pair", "/create"},
          {"calls", "Call Option Onchain", "/stock/covered-call"},
          {"after-hours", "Isolated After-hours Exposure", "/stock/isolated-afters"}
        ] do
      assert has_element?(view, "h2#home-product-#{id}-title", title)
      assert has_element?(view, "#home-product-#{id}-more li")
      assert has_element?(view, "#home-product-#{id}-more a[href='#{path}']")
    end

    assert has_element?(view, "#home-products.home-products--open")
    refute has_element?(view, "#home-products[phx-hook]")
    refute has_element?(view, "#home-products [aria-expanded]")
    refute has_element?(view, "#home-product-revstake")

    order = view |> render() |> then(&Regex.scan(~r/id="home-product-([a-z-]+)-title"/, &1))
    assert Enum.map(order, &List.last/1) == ~w(memestock calls after-hours)
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
      assert conn |> get(path) |> html_response(200) =~ "Onchain token address"
    end

    # The list carries the stocks, not their details.
    refute listing =~ "Onchain token address"
  end

  test "a symbol is read in any case, and one the listing does not hold is not found",
       %{conn: conn} do
    assert conn |> get("/stocks/aaplc") |> html_response(200) =~ "Apple Inc."

    {404, _headers, _body} =
      assert_error_sent(404, fn -> get(conn, "/stocks/NOTASTOCK") end)
  end
end
