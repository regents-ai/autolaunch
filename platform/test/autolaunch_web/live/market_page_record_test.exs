defmodule AutolaunchWeb.MarketPageRecordTest do
  @moduledoc """
  An auction's or a token's page names its own record in the public API, and
  its structured data describes that auction or token. An agent that lands on
  the page follows the link and reads the same record the page shows.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport
  alias AutolaunchWeb.{Paths, PublicDocuments}

  test "each auction and token page links its own API record and describes it", %{conn: conn} do
    stored = TestSupport.project_auction(chain_id: 8453, symbol: "RECORD", state: :graduated)
    {:ok, auction} = Paths.find_auction("RECORD", String.slice(stored.auction_address, -5, 5))
    token = TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    for {page, id, type, address} <- [
          {Paths.auction(auction), auction.id, "Event", auction.auction_address},
          {Paths.token(auction), token.id, "FinancialProduct", auction.token_address}
        ] do
      document = conn |> get(page) |> html_response(200) |> LazyHTML.from_document()

      [record] =
        document
        |> LazyHTML.query(~s(link[rel="alternate"][type="application/json"]))
        |> LazyHTML.attribute("href")

      assert %{"data" => %{"id" => ^id}} =
               conn |> get(URI.parse(record).path) |> json_response(200)

      json_ld =
        document |> LazyHTML.query(~s(script[type="application/ld+json"])) |> LazyHTML.text()

      %{"@graph" => graph} = Jason.decode!(json_ld)
      entity = Enum.find(graph, &(&1["@type"] == type))
      assert entity["url"] == PublicDocuments.url(page)
      assert entity["subjectOf"]["contentUrl"] == record
      if address, do: assert(entity["identifier"] == "eip155:8453:#{address}")
      refute Enum.any?(graph, &(&1["@type"] == "WebApplication"))
    end
  end
end
