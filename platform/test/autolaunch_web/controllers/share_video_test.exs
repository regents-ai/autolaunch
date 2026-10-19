defmodule AutolaunchWeb.ShareVideoTest do
  @moduledoc """
  A wallet's own share video shows that wallet's bids, trades, stake and
  earnings, so only the signed-in account that links the wallet may fetch it.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport
  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  test "WALLET_VIDEO_ONLY_FOR_ITS_OWNER: anyone else finds nothing at the address", %{conn: conn} do
    stored = TestSupport.project_auction(chain_id: 8453, symbol: "VIDEO", state: :graduated)

    TestSupport.project_token(
      auction_id: stored.id,
      symbol: "VIDEO",
      graduated_at: DateTime.utc_now()
    )

    {:ok, auction, _token} =
      Paths.find_token("VIDEO", String.slice(stored.auction_address, -5, 5))

    owner = TestSupport.register_creator!()
    other = TestSupport.register_creator!()
    wallet = String.downcase(owner.wallet_address)
    token_path = URI.parse(Paths.wallet_video_url(auction, wallet, "1")).path

    auction_path =
      URI.parse(Paths.auction_wallet_video_url(auction, wallet, "1")).path

    for path <- [token_path, auction_path], session <- [%{}, %{human_account_id: other.id}] do
      {404, _headers, _body} =
        assert_error_sent(404, fn -> conn |> init_test_session(session) |> get(path) end)
    end

    # The owner is let through both: their video, already waiting in line
    # (the tests run no job queue), answers its place, and the graduated
    # auction's address moves on to the token's.
    Autolaunch.Repo.insert_all("share_video_requests", [
      %{
        id: Ecto.UUID.bingenerate(),
        key: "#{auction.id}:token:account:#{owner.id}",
        kind: "token",
        auction_id: Ecto.UUID.dump!(auction.id),
        human_account_id: owner.id,
        wallet: wallet,
        state: "queued"
      }
    ])

    queued = conn |> init_test_session(%{human_account_id: owner.id}) |> get(token_path)
    assert %{"ahead" => 0} = json_response(queued, 202)

    moved = conn |> init_test_session(%{human_account_id: owner.id}) |> get(auction_path)
    assert moved.status == 301
    assert URI.parse(redirected_to(moved, 301)).path == token_path
  end
end
