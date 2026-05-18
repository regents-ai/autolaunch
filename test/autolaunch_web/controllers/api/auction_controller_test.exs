defmodule AutolaunchWeb.Api.AuctionControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_auctions(filters, _human) do
      base = [
        %{
          id: "auc_1",
          agent_name: "Atlas",
          phase: "biddable",
          current_price_quote: "0.0050",
          implied_market_cap_quote: "500000000"
        }
      ]

      case filters["mode"] do
        "live" ->
          [
            %{
              id: "auc_2",
              agent_name: "Nova",
              phase: "live",
              current_price_quote: "0.0110",
              implied_market_cap_quote: "1100000000"
            }
          ]

        _ ->
          base
      end
    end

    def get_auction("auc_missing", _human), do: nil

    def get_auction(id, _human) do
      %{id: id, agent_name: "Atlas", status: "active", current_clearing_price: "0.0050"}
    end

    def quote_bid("auc_missing", _params, _human), do: {:error, :auction_not_found}
    def quote_bid("auc_sold", _params, _human), do: {:error, :auction_sold_out}

    def quote_bid(id, params, human) do
      {:ok,
       %{
         auction_id: id,
         amount: params["amount"],
         max_price: params["max_price"],
         current_clearing_price: "0.0050",
         projected_clearing_price: "0.0057",
         quote_mode: "onchain_exact_v1",
         would_be_active_now: true,
         status_band: "active",
         estimated_tokens_if_end_now: "0",
         estimated_tokens_if_no_other_bids_change: "12",
         inactive_above_price: "0.0049",
         time_remaining_seconds: 86_400,
         warnings: ["Watch the next checkpoint."],
         prepared:
           if(human,
             do: %{
               action_id: "bid_quote",
               owner_product: "autolaunch",
               resource: "auction",
               resource_id: id,
               action: "submit_bid",
               chain_id: 8_453,
               expected_signer: "0x1111111111111111111111111111111111111111",
               expires_at: "2999-01-01T00:00:00Z",
               idempotency_key: "bid_quote",
               risk_copy: "Submits a Base $REGENT bid for this auction.",
               wallet_action: %{
                 action_id: "bid_quote",
                 owner_product: "autolaunch",
                 resource: "auction",
                 resource_id: id,
                 action: "submit_bid",
                 chain_id: 8_453,
                 to: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                 value: "0x0",
                 data: "0x1234",
                 expected_signer: "0x1111111111111111111111111111111111111111",
                 expires_at: "2999-01-01T00:00:00Z",
                 idempotency_key: "bid_quote",
                 simulation: %{required: false, status: "not_required", block_number: nil},
                 risk_copy: "Submits a Base $REGENT bid for this auction."
               }
             },
             else: nil
           )
       }}
    end

    def place_bid(_id, %{"tx_hash" => "0x" <> "p" <> _rest}, _human),
      do: {:error, :transaction_pending}

    def place_bid(id, _params, _human) do
      {:ok, %{bid_id: "#{id}:7", status: "active"}}
    end
  end

  setup %{conn: conn} do
    original = Application.get_env(:autolaunch, :auction_controller, [])
    Application.put_env(:autolaunch, :auction_controller, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :auction_controller, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:auction-controller", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Bidder"
      })

    %{conn: conn, human: human}
  end

  test "index returns a non-empty auction payload", %{conn: conn} do
    conn = get(conn, "/v1/app/auctions?mode=biddable&sort=newest")

    assert %{"ok" => true, "items" => [%{"id" => "auc_1"}]} = json_response(conn, 200)
  end

  test "show returns not found when the auction is missing", %{conn: conn} do
    conn = get(conn, "/v1/app/auctions/auc_missing")

    assert %{"ok" => false, "error" => %{"code" => "auction_not_found"}} =
             json_response(conn, 404)
  end

  test "bid_quote returns the live estimator and prepared action for signed-in users", %{
    conn: conn,
    human: human
  } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/v1/app/auctions/auc_1/bid_quote", %{
        "amount" => "250.0",
        "max_price" => "0.0060"
      })

    assert %{
             "ok" => true,
             "auction_id" => "auc_1",
             "status_band" => "active",
             "prepared" => %{
               "expected_signer" => @wallet,
               "wallet_action" => %{"chain_id" => 8_453}
             }
           } = json_response(conn, 200)
  end

  test "bid_quote returns specific auction lifecycle errors", %{conn: conn} do
    conn =
      post(conn, "/v1/app/auctions/auc_sold/bid_quote", %{
        "amount" => "250.0",
        "max_price" => "0.0060"
      })

    assert %{"ok" => false, "error" => %{"code" => "auction_sold_out"}} = json_response(conn, 422)
  end

  test "create_bid returns accepted while the chain tx is pending", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    tx_hash = "0x" <> "p" <> String.duplicate("1", 63)

    conn = post(conn, "/v1/app/auctions/auc_1/bids", %{"tx_hash" => tx_hash})

    assert %{"ok" => false, "error" => %{"code" => "transaction_pending"}} =
             json_response(conn, 202)
  end

  test "create_bid returns created when the bid is registered", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/v1/app/auctions/auc_1/bids", %{"tx_hash" => "0x" <> String.duplicate("1", 64)})

    assert %{"ok" => true, "bid" => %{"bid_id" => "auc_1:7", "status" => "active"}} =
             json_response(conn, 201)
  end
end
