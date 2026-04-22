defmodule AutolaunchWeb.AuctionReturnsLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_auction_returns(_filters, _human) do
      %{
        items: [
          %{
            id: "ret_1",
            agent_id: "84532:42",
            agent_name: "Atlas",
            symbol: "ATLAS",
            detail_url: "/auctions/ret_1",
            currency_raised: "18240.75",
            total_bid_volume: "18240.75",
            required_currency_raised: "100000.00",
            minimum_raise_progress_percent: 18,
            minimum_raise_met: false,
            ends_at: DateTime.add(DateTime.utc_now(), -86_400, :second) |> DateTime.to_iso8601(),
            your_bid_status: "Returns open"
          },
          %{
            id: "ret_2",
            agent_id: "8453:7",
            agent_name: "Cinder",
            symbol: "CNDR",
            detail_url: "/auctions/ret_2",
            currency_raised: "9250.00",
            total_bid_volume: "9250.00",
            required_currency_raised: "100000.00",
            minimum_raise_progress_percent: 9,
            minimum_raise_met: false,
            ends_at: DateTime.add(DateTime.utc_now(), -172_800, :second) |> DateTime.to_iso8601(),
            your_bid_status: "Watching only"
          }
        ],
        next_offset: "more"
      }
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :auction_returns_live, [])
    Application.put_env(:autolaunch, :auction_returns_live, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :auction_returns_live, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:auction-returns-live", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Bidder"
      })

    %{human: human}
  end

  test "returns page renders as an auctions subpage with dense rows", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/auction-returns")

    assert html =~ "Auctions"
    assert html =~ "Auction returns"
    assert html =~ "Failed auctions"
    assert html =~ "Tracked bids"
    assert html =~ "Atlas"
    assert html =~ "Cinder"
    assert html =~ "Open return path"
    assert html =~ "Open positions"
    assert html =~ "Loading more failed auctions"
  end
end
