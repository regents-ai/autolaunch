defmodule AutolaunchWeb.PositionsLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{Accounts, Tokens}

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_positions(nil, _filters), do: []

    def list_positions(_human, filters) do
      positions = [
        %{
          bid_id: "bid_exit",
          auction_id: "auc_1",
          agent_name: "Atlas",
          chain: "Base",
          status: "inactive",
          amount: "250.0",
          max_price: "0.0060",
          current_clearing_price: "0.0065",
          inactive_above_price: "0.0060",
          next_action_label: "Exit this bid and settle the refund.",
          tx_actions: %{
            exit: %{
              prepared: %{
                wallet_action: %{
                  chain_id: 8_453,
                  to: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  data: "0xexit",
                  value: "0x0"
                }
              }
            },
            claim: nil
          }
        },
        %{
          bid_id: "bid_claim",
          auction_id: "auc_2",
          agent_name: "Nova",
          chain: "Base",
          status: "claimable",
          amount: "100.0",
          max_price: "0.0045",
          current_clearing_price: "0.0040",
          inactive_above_price: "0.0039",
          next_action_label: "Claim purchased tokens now.",
          auction: %{
            auction_outcome: "graduated",
            chain_id: 8_453,
            token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            token_symbol: "NOVA"
          },
          tx_actions: %{
            exit: nil,
            claim: %{
              prepared: %{
                wallet_action: %{
                  chain_id: 8_453,
                  to: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                  data: "0xclaim",
                  value: "0x0"
                }
              }
            }
          }
        },
        %{
          bid_id: "bid_claimed",
          auction_id: "auc_4",
          agent_name: "Vega",
          chain: "Base",
          status: "claimed",
          amount: "75.0",
          max_price: "0.0050",
          current_clearing_price: "0.0042",
          inactive_above_price: "0.0041",
          next_action_label: "Purchased tokens are in your wallet.",
          auction: %{
            auction_outcome: "graduated",
            chain_id: 8_453,
            token_address: "0xcccccccccccccccccccccccccccccccccccccccc",
            token_symbol: "VEGA"
          },
          tx_actions: %{
            exit: nil,
            claim: nil
          }
        },
        %{
          bid_id: "bid_paused_claimed",
          auction_id: "auc_5",
          agent_name: "Paused",
          chain: "Base",
          status: "claimed",
          amount: "60.0",
          max_price: "0.0050",
          current_clearing_price: "0.0042",
          inactive_above_price: "0.0041",
          next_action_label: "Purchased tokens are in your wallet.",
          auction: %{
            auction_outcome: "graduated",
            chain_id: 8_453,
            token_address: "0xdddddddddddddddddddddddddddddddddddddddd",
            token_symbol: "PAUS"
          },
          tx_actions: %{
            exit: nil,
            claim: nil
          }
        },
        %{
          bid_id: "bid_soon",
          auction_id: "auc_3",
          agent_name: "Ember",
          chain: "Base",
          status: "active",
          amount: "50.0",
          max_price: "0.0070",
          current_clearing_price: "0.0068",
          inactive_above_price: "0.0067",
          next_action_label: "Bid is still participating.",
          auction: %{
            ends_at: DateTime.add(DateTime.utc_now(), 1_200, :second) |> DateTime.to_iso8601()
          },
          tx_actions: %{
            exit: nil,
            claim: nil
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
    original_swaps = Application.get_env(:autolaunch, :swaps, [])
    Application.put_env(:autolaunch, :positions_live, launch_module: LaunchStub)

    Application.put_env(
      :autolaunch,
      :swaps,
      Keyword.merge(original_swaps, enabled: false, uniswap_api_key: "")
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :positions_live, original)
      Application.put_env(:autolaunch, :swaps, original_swaps)
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
    {:ok, view, html} = live(conn, "/positions")

    assert html =~ "Portfolio overview"
    assert html =~ "Returns available"
    assert html =~ "Closing soon"
    assert html =~ "Needs attention"
    assert html =~ "Recent activity"
    assert html =~ "Search by token or auction ID"
    assert html =~ "Exit bid"
    assert html =~ "Claim tokens"
    refute has_element?(view, "[data-swap-open]")
    assert html =~ "Atlas"
    assert html =~ "Nova"
    assert html =~ "Ember"
  end

  test "swap controls render only when swaps are available", %{conn: conn, human: human} do
    swaps = Application.get_env(:autolaunch, :swaps, [])

    Application.put_env(
      :autolaunch,
      :swaps,
      Keyword.merge(swaps,
        enabled: true,
        uniswap_api_key: "test-key",
        allowed_transaction_targets: %{8_453 => ["0x3333333333333333333333333333333333333333"]},
        allowed_approval_spenders: %{8_453 => ["0x2222222222222222222222222222222222222222"]}
      )
    )

    insert_revsplit_token(%{
      token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      source_auction_id: "auc_2",
      agent_name: "Nova",
      token_symbol: "NOVA"
    })

    insert_revsplit_token(%{
      token_address: "0xcccccccccccccccccccccccccccccccccccccccc",
      source_auction_id: "auc_4",
      agent_name: "Vega",
      token_symbol: "VEGA"
    })

    insert_revsplit_token(%{
      token_address: "0xdddddddddddddddddddddddddddddddddddddddd",
      source_auction_id: "auc_5",
      agent_name: "Paused",
      token_symbol: "PAUS",
      revsplit_status: "paused"
    })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/positions")

    assert has_element?(view, "#position-row-bid_claim [data-swap-open][data-swap-side='buy']")
    refute has_element?(view, "#position-row-bid_claim [data-swap-open][data-swap-side='sell']")
    assert has_element?(view, "#position-row-bid_claimed [data-swap-open][data-swap-side='sell']")
    refute has_element?(view, "#position-row-bid_paused_claimed [data-swap-open]")
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

  test "attention filters show bids closing soon", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/positions")

    html =
      view
      |> element(".al-positions-filter-row button[phx-value-status='closing_soon']")
      |> render_click()

    assert html =~ "Ember"
    refute has_element?(view, "#position-row-bid_exit")
    refute has_element?(view, "#position-row-bid_claim")
  end

  defp insert_revsplit_token(attrs) do
    now = DateTime.utc_now()

    defaults = %{
      chain_id: 8_453,
      token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      source_auction_id: "auc_swap",
      source_job_id: "job_swap",
      auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      agent_id: "8453:1",
      agent_name: "Swap Agent",
      token_symbol: "SWAP",
      subject_id: "0x" <> String.duplicate("1", 64),
      splitter_address: "0xcccccccccccccccccccccccccccccccccccccccc",
      pool_id: "0x" <> String.duplicate("2", 64),
      graduated_at: now,
      graduation_block: 200,
      revsplit_status: "active",
      last_synced_at: now
    }

    {:ok, token} = Tokens.upsert_revsplit_token(Map.merge(defaults, attrs))
    token
  end
end
