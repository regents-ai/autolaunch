defmodule AutolaunchWeb.Api.MeControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_positions(nil, _filters), do: []

    def list_positions(_human, filters) do
      items = [
        %{bid_id: "bid_active", auction_id: "auc_1", status: "active"},
        %{bid_id: "bid_claimable", auction_id: "auc_2", status: "claimable"}
      ]

      case filters["status"] do
        nil -> items
        "" -> items
        status -> Enum.filter(items, &(&1.status == status))
      end
    end
  end

  setup %{conn: conn} do
    original = Application.get_env(:autolaunch, :me_controller, [])
    Application.put_env(:autolaunch, :me_controller, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :me_controller, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:me-controller", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Bidder"
      })

    %{conn: conn, human: human}
  end

  test "bids still require auth", %{conn: conn} do
    conn = get(conn, "/api/me/bids")
    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} = json_response(conn, 401)
  end

  test "bids filters by status and auction id", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    conn = get(conn, "/api/me/bids?status=claimable&auction=auc_2")

    assert %{"ok" => true, "items" => [%{"bid_id" => "bid_claimable", "auction_id" => "auc_2"}]} =
             json_response(conn, 200)
  end
end
