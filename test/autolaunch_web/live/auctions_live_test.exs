defmodule AutolaunchWeb.AuctionsLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def chain_options do
      [%{key: "ethereum-sepolia", label: "Ethereum Sepolia"}]
    end

    def list_auctions(filters, _human) do
      auctions = [
        %{
          id: "auc_active",
          agent_id: "11155111:42",
          agent_name: "Atlas",
          symbol: "ATLAS",
          chain: "Ethereum Sepolia",
          network: "ethereum-sepolia",
          status: "active",
          your_bid_status: "active",
          current_clearing_price: "0.0050",
          total_bid_volume: "200",
          ends_at: DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.to_iso8601(),
          bidders: 12,
          ens_attached: true,
          ens_name: "atlas.eth",
          world_registered: true,
          world_launch_count: 2
        },
        %{
          id: "auc_pending",
          agent_id: "11155111:99",
          agent_name: "Nova",
          symbol: "NOVA",
          chain: "Ethereum Sepolia",
          network: "ethereum-sepolia",
          status: "settled",
          your_bid_status: "none",
          current_clearing_price: "0.0040",
          total_bid_volume: "150",
          ends_at: DateTime.add(DateTime.utc_now(), -600, :second) |> DateTime.to_iso8601(),
          bidders: 8,
          ens_attached: false,
          ens_name: nil,
          world_registered: false,
          world_launch_count: 0
        }
      ]

      auctions
      |> maybe_filter_status(filters["status"])
      |> maybe_filter_mine(filters["mine_only"])
    end

    defp maybe_filter_status(items, nil), do: items
    defp maybe_filter_status(items, ""), do: items
    defp maybe_filter_status(items, "active"), do: Enum.filter(items, &(&1.status == "active"))
    defp maybe_filter_status(items, value), do: Enum.filter(items, &(&1.status == value))

    defp maybe_filter_mine(items, value) when value in [true, "true", "1"],
      do: Enum.filter(items, &(&1.your_bid_status not in [nil, "none"]))

    defp maybe_filter_mine(items, _value), do: items
  end

  setup do
    original = Application.get_env(:autolaunch, :auctions_live, [])
    Application.put_env(:autolaunch, :auctions_live, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :auctions_live, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:auctions-live", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Bidder"
      })

    %{human: human}
  end

  test "auctions page renders non-empty listings and trust completion copy", %{
    conn: conn,
    human: human
  } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/auctions")

    assert html =~ "Atlas"

    assert html =~
             "ENS is linked, the trust check is complete, and this operator has launched 2 tokens through autolaunch."

    assert html =~ "Inspect auction"
  end

  test "auctions filters narrow the list to the user's active market", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/auctions")

    html =
      view
      |> form("form[phx-change='filters_changed']", %{
        "filters" => %{"status" => "active", "mine_only" => "on"}
      })
      |> render_change()

    assert html =~ "Atlas"
    refute html =~ "Nova"
  end
end
