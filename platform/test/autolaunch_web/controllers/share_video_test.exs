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
    path = URI.parse(Paths.wallet_video_url(auction, owner.wallet_address, "1")).path

    for session <- [%{}, %{human_account_id: other.id}] do
      {404, _headers, _body} =
        assert_error_sent(404, fn -> conn |> init_test_session(session) |> get(path) end)
    end

    # The owner is let through; with no chain to read in tests, the video
    # cannot be made, which is the try-again page rather than not found.
    {503, _headers, _body} =
      assert_error_sent(503, fn ->
        conn |> init_test_session(%{human_account_id: owner.id}) |> get(path)
      end)
  end
end
