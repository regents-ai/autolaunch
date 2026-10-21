defmodule AutolaunchWeb.StockListingTest do
  @moduledoc """
  The stock listing is a short list whose every stock opens its own page with
  its details; each of those pages answers and is in the sitemap, and a
  symbol the listing does not hold is the not-found page.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Stocks.UpcomingCatalog

  test "every listed stock opens its own page, which the sitemap lists", %{conn: conn} do
    listing = conn |> get("/stock-listing") |> html_response(200)
    sitemap = conn |> get("/sitemap.xml") |> response(200)

    links =
      ~r{href="(/stock-listing/[^"]+)"}
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
    assert conn |> get("/stock-listing/aaplc") |> html_response(200) =~ "Apple Inc."

    {404, _headers, _body} =
      assert_error_sent(404, fn -> get(conn, "/stock-listing/NOTASTOCK") end)
  end
end
