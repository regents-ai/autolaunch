defmodule AutolaunchWeb.PositionsLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_positions(nil, _filters), do: []

    def list_positions(_human, filters) do
      positions = [
        %{
          bid_id: "bid_exit",
          auction_id: "auc_1",
          agent_name: "Atlas",
          chain: "Ethereum Sepolia",
          status: "inactive",
          amount: "250.0",
          max_price: "0.0060",
          current_clearing_price: "0.0065",
          inactive_above_price: "0.0060",
          next_action_label: "Exit this bid and settle the refund.",
          tx_actions: %{
            exit: %{
              tx_request: %{
                chain_id: 11_155_111,
                to: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                data: "0xexit",
                value: "0x0"
              }
            },
            claim: nil
          }
        },
        %{
          bid_id: "bid_claim",
          auction_id: "auc_2",
          agent_name: "Nova",
          chain: "Ethereum Sepolia",
          status: "claimable",
          amount: "100.0",
          max_price: "0.0045",
          current_clearing_price: "0.0040",
          inactive_above_price: "0.0039",
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

      case filters["status"] do
        nil -> positions
        "" -> positions
        status -> Enum.filter(positions, &(&1.status == status))
      end
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :positions_live, [])
    Application.put_env(:autolaunch, :positions_live, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :positions_live, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:positions-live", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Bidder"
      })

    %{human: human}
  end

  test "signed-in positions render exit and claim actions", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/positions")

    assert html =~ "Exit bid"
    assert html =~ "Claim tokens"
    assert html =~ "Atlas"
    assert html =~ "Nova"
  end

  test "status filters narrow the signed-in positions list", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/positions")

    html =
      view
      |> form("form[phx-change='filters_changed']", %{"filters" => %{"status" => "claimable"}})
      |> render_change()

    assert html =~ "Nova"
    refute html =~ "Atlas"
    assert html =~ "Claim tokens"
    refute html =~ "Exit bid"
  end
end
