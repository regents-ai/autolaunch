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
          chain: "Base Sepolia",
          status: "inactive",
          amount: "250.0",
          max_price: "0.0060",
          current_clearing_price: "0.0065",
          inactive_above_price: "0.0060",
          next_action_label: "Exit this bid and settle the refund.",
          tx_actions: %{
            exit: %{
              tx_request: %{
                chain_id: 84_532,
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
          chain: "Base Sepolia",
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
                chain_id: 84_532,
                to: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                data: "0xclaim",
                value: "0x0"
              }
            }
          }
        }
      ]

      positions =
        case filters["status"] do
          nil -> positions
          "" -> positions
          status -> Enum.filter(positions, &(&1.status == status))
        end

      case String.trim(filters["search"] || "") do
        "" ->
          positions

        query ->
          downcased = String.downcase(query)

          Enum.filter(positions, fn position ->
            Enum.any?(
              [position.agent_name, position.auction_id, position.bid_id],
              &(is_binary(&1) and String.contains?(String.downcase(&1), downcased))
            )
          end)
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

    assert html =~ "Portfolio overview"
    assert html =~ "Returns available"
    assert html =~ "Recent activity"
    assert html =~ "Search by token or auction ID"
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
      |> element(".al-positions-filter-row button[phx-value-status='claimable']")
      |> render_click()

    assert html =~ "Nova"
    refute has_element?(view, "#position-row-bid_exit")
    assert has_element?(view, "#position-row-bid_claim")
    assert html =~ "Claim tokens"
    refute html =~ "Exit bid"
  end

  test "search narrows the positions table", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/positions")

    html =
      view
      |> form("form[phx-change='filters_changed']", %{"filters" => %{"search" => "auc_1"}})
      |> render_change()

    assert html =~ "Atlas"
    refute has_element?(view, "#position-row-bid_claim")
    assert has_element?(view, "#position-row-bid_exit")
    assert html =~ "Exit bid"
  end

  test "query params restore a shared positions view", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, html} = live(conn, "/positions?status=claimable&search=nova")

    assert html =~ "Nova"
    assert has_element?(view, "#position-row-bid_claim")
    refute has_element?(view, "#position-row-bid_exit")
    assert html =~ "Review claims"
  end
end
