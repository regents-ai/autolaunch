defmodule AutolaunchWeb.BidControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  @removed [
    "/api/v1/auctions/:id/bids",
    "/api/v1/bids/:id/exit",
    "/api/v1/bids/:id/return",
    "/api/v1/bids/:id/claim"
  ]

  test "THE_OBSOLETE_ACTION_PATH_IS_GONE: no route can prepare a bid or a bid position" do
    paths = Enum.map(AutolaunchWeb.Router.__routes__(), & &1.path)

    for path <- @removed, do: refute(path in paths)
    assert "/api/v1/auctions/:id/bid-quote" in paths

    refute Enum.any?(paths, &String.contains?(&1, "submit"))
    refute Enum.any?(paths, &String.contains?(&1, "broadcast"))
  end

  test "THE_OBSOLETE_ACTION_PATH_IS_GONE: the controller exposes only public auction reads" do
    exported =
      AutolaunchWeb.AuctionController.__info__(:functions)
      |> Keyword.keys()
      |> Enum.filter(
        &(&1 in [
            :index,
            :show,
            :bid_quote,
            :prepare_bid,
            :prepare_bid_exit,
            :prepare_bid_return,
            :prepare_bid_claim
          ])
      )
      |> Enum.sort()

    assert exported == [:bid_quote, :index, :show]
  end
end
