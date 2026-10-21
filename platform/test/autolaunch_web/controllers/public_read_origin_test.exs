defmodule AutolaunchWeb.PublicReadOriginTest do
  @moduledoc """
  Any website's page may read the public reads from its visitors' browsers:
  they carry no cookie and need no sign-in. Every route that reads or acts
  for a signed-in person or a paired agent stays readable from this site only.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport
  alias AutolaunchWeb.AuctionController

  # The auction list keeps an answer for a few seconds; this case's must not
  # answer the next case's read.
  setup do
    on_exit(fn -> Cachex.clear(AuctionController.cache()) end)
  end

  test "the public reads allow any origin, and no signed or account route does", %{conn: conn} do
    auction = TestSupport.project_auction(chain_id: 8453, state: :graduated)
    token = TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    public = [
      "/api/v1/auctions",
      "/api/v1/auctions/#{auction.id}",
      "/api/v1/auction-counts",
      "/api/v1/tokens",
      "/api/v1/tokens/#{token.id}",
      "/api/v1/treasury-security/0x1111111111111111111111111111111111111111"
    ]

    for path <- public do
      response = conn |> put_req_header("origin", "https://elsewhere.example") |> get(path)
      assert get_resp_header(response, "access-control-allow-origin") == ["*"], path
      assert get_resp_header(response, "access-control-allow-credentials") == [], path
    end

    private = [
      {:get, "/api/v1/me/positions"},
      {:get, "/api/v1/profile"},
      {:get, "/api/agent/v1/drafts/revstake"},
      {:get, "/api/agent/v1/positions"},
      {:get, "/api/agents/v1/whoami"},
      {:post, "/api/v1/auctions/#{auction.id}/bid-quote"}
    ]

    for {method, path} <- private do
      response =
        build_conn()
        |> put_req_header("origin", "https://elsewhere.example")
        |> put_req_header("accept", "application/json")
        |> dispatch(@endpoint, method, path, %{})

      assert get_resp_header(response, "access-control-allow-origin") == [], path
    end
  end
end
