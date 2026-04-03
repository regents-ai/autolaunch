defmodule AutolaunchWeb.AuctionLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def get_auction("auc_1", _human) do
      %{
        id: "auc_1",
        agent_name: "Atlas",
        current_clearing_price: "0.0050",
        total_bid_volume: "200.0",
        ends_at: DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.to_iso8601(),
        status: "active",
        ens_attached: true,
        ens_name: "atlas.eth",
        world_registered: true,
        world_human_id: "world_1",
        world_launch_count: 2,
        chain: "Ethereum Sepolia"
      }
    end

    def get_auction(_id, _human), do: nil

    def quote_bid("auc_1", %{"amount" => amount, "max_price" => max_price}, human)
        when amount not in ["", nil] and max_price not in ["", nil] do
      {:ok,
       %{
         amount: amount,
         max_price: max_price,
         current_clearing_price: "0.0050",
         projected_clearing_price: "0.0057",
         would_be_active_now: true,
         status_band: "active",
         estimated_tokens_if_end_now: "0",
         estimated_tokens_if_no_other_bids_change: "12",
         inactive_above_price: "0.0049",
         time_remaining_seconds: 86_400,
         warnings: ["Watch the next checkpoint."],
         tx_request:
           if(human,
             do: %{
               chain_id: 11_155_111,
               to: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               data: "0x1234",
               value: "0x0"
             },
             else: nil
           )
       }}
    end

    def quote_bid(_id, _params, _human), do: {:error, :invalid_quote_input}

    def list_positions(nil), do: []

    def list_positions(_human) do
      [
        %{
          bid_id: "bid_1",
          auction_id: "auc_1",
          status: "claimable",
          amount: "250.0",
          max_price: "0.0060",
          tokens_filled: "12",
          estimated_tokens_if_end_now: "0",
          inactive_above_price: "0.0049",
          next_action_label: "Claim purchased tokens now.",
          tx_actions: %{
            exit: nil,
            claim: %{
              tx_request: %{
                chain_id: 11_155_111,
                to: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                data: "0xclaim",
                value: "0x0"
              }
            }
          }
        }
      ]
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :auction_live, [])
    Application.put_env(:autolaunch, :auction_live, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :auction_live, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:auction-live", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Bidder"
      })

    %{human: human}
  end

  test "auction detail renders the estimator and claim action for signed-in users", %{
    conn: conn,
    human: human
  } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/auctions/auc_1")

    assert html =~ "Detail strip"
    assert html =~ "The detail terrain stays orienting only."
    assert html =~ "Bid composer"
    assert html =~ "real budget and your real max price"
    assert html =~ "Submit bid from wallet"
    assert html =~ "Claim tokens"
    assert html =~ "Identity and trust status"
  end

  test "aggressive preset updates the form and keeps the submit path visible", %{
    conn: conn,
    human: human
  } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/auctions/auc_1")

    html =
      view
      |> element("button[phx-value-preset='aggressive']")
      |> render_click()

    assert html =~ ~s(value="500.0")
    assert html =~ "Submit bid from wallet"
  end

  test "guest view removes the wallet submit path", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/auctions/auc_1")

    refute html =~ "Submit bid from wallet"
    assert html =~ "Privy session required before the wallet transaction can be registered."
  end

  test "detail strip back returns focus to bid composer", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/auctions/auc_1")

    html =
      view
      |> element("#auction-detail-regent-surface-scene")
      |> render_hook("regent:node_select", %{
        "target_id" => "detail:trust",
        "face_id" => "auction",
        "meta" => %{"panel" => "detail:trust"}
      })

    assert html =~ "Back to overview"

    html =
      view
      |> element("button[phx-click='scene-back']")
      |> render_click()

    refute html =~ "Back to overview"
    assert html =~ "Bid composer"
  end
end
