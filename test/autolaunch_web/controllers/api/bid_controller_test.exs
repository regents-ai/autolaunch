defmodule AutolaunchWeb.Api.BidControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def exit_bid(_id, _params, nil), do: {:error, :unauthorized}
    def exit_bid("bid_forbidden", _params, _human), do: {:error, :forbidden}
    def exit_bid("bid_pending", _params, _human), do: {:error, :transaction_pending}

    def exit_bid(id, _params, human) when not is_nil(human),
      do: {:ok, %{bid_id: id, status: "exited"}}

    def claim_bid(_id, _params, nil), do: {:error, :unauthorized}
    def claim_bid("bid_missing", _params, _human), do: {:error, :not_found}
    def claim_bid("bid_pending", _params, _human), do: {:error, :transaction_pending}

    def claim_bid(id, _params, human) when not is_nil(human),
      do: {:ok, %{bid_id: id, status: "claimed"}}
  end

  setup %{conn: conn} do
    original = Application.get_env(:autolaunch, :bid_controller, [])
    Application.put_env(:autolaunch, :bid_controller, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :bid_controller, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:bid-controller", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Bidder"
      })

    %{conn: conn, human: human}
  end

  test "exit returns the updated bid position", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/v1/app/bids/bid_1/exit", %{"tx_hash" => "0x" <> String.duplicate("1", 64)})

    assert %{"ok" => true, "bid" => %{"bid_id" => "bid_1", "status" => "exited"}} =
             json_response(conn, 200)
  end

  test "exit returns the bid_forbidden error", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/v1/app/bids/bid_forbidden/exit", %{
        "tx_hash" => "0x" <> String.duplicate("2", 64)
      })

    assert %{"ok" => false, "error" => %{"code" => "bid_forbidden"}} = json_response(conn, 403)
  end

  test "claim returns accepted while confirmation is pending", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/v1/app/bids/bid_pending/claim", %{
        "tx_hash" => "0x" <> String.duplicate("3", 64)
      })

    assert %{"ok" => false, "error" => %{"code" => "transaction_pending"}} =
             json_response(conn, 202)
  end

  test "claim returns not found for unknown bids", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/v1/app/bids/bid_missing/claim", %{
        "tx_hash" => "0x" <> String.duplicate("4", 64)
      })

    assert %{"ok" => false, "error" => %{"code" => "bid_not_found"}} = json_response(conn, 404)
  end
end
