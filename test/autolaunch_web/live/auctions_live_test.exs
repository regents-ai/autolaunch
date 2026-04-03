defmodule AutolaunchWeb.AuctionsLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_auctions(filters, _human) do
      rows = [
        %{
          id: "auc_active",
          agent_id: "11155111:42",
          agent_name: "Atlas",
          symbol: "ATLAS",
          phase: "biddable",
          price_source: "auction_clearing",
          current_price_usdc: "0.0050",
          implied_market_cap_usdc: "500000000",
          detail_url: "/auctions/auc_active",
          subject_url: "/subjects/0x" <> String.duplicate("1", 64),
          uniswap_url: "https://example.com/atlas",
          started_at: DateTime.add(DateTime.utc_now(), -300, :second) |> DateTime.to_iso8601(),
          ends_at: DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.to_iso8601(),
          trust: %{
            ens: %{connected: true, name: "atlas.eth"},
            world: %{connected: true, launch_count: 2}
          }
        },
        %{
          id: "auc_live",
          agent_id: "11155111:99",
          agent_name: "Nova",
          symbol: "NOVA",
          phase: "live",
          price_source: "uniswap_spot",
          current_price_usdc: "0.0110",
          implied_market_cap_usdc: "1100000000",
          detail_url: "/auctions/auc_live",
          subject_url: "/subjects/0x" <> String.duplicate("2", 64),
          uniswap_url: "https://example.com/nova",
          started_at:
            DateTime.add(DateTime.utc_now(), -172_800, :second) |> DateTime.to_iso8601(),
          ends_at: DateTime.add(DateTime.utc_now(), -86_400, :second) |> DateTime.to_iso8601(),
          trust: %{
            ens: %{connected: false, name: nil},
            world: %{connected: false, launch_count: 0}
          }
        }
      ]

      rows
      |> maybe_filter_mode(filters["mode"])
      |> maybe_sort(filters["sort"])
    end

    defp maybe_filter_mode(items, nil), do: Enum.filter(items, &(&1.phase == "biddable"))
    defp maybe_filter_mode(items, ""), do: Enum.filter(items, &(&1.phase == "biddable"))
    defp maybe_filter_mode(items, "all"), do: items
    defp maybe_filter_mode(items, mode), do: Enum.filter(items, &(&1.phase == mode))

    defp maybe_sort(items, "oldest"), do: Enum.reverse(items)

    defp maybe_sort(items, "market_cap_desc"),
      do: Enum.sort_by(items, &Decimal.new(&1.implied_market_cap_usdc), :desc)

    defp maybe_sort(items, "market_cap_asc"),
      do: Enum.sort_by(items, &Decimal.new(&1.implied_market_cap_usdc), :asc)

    defp maybe_sort(items, _sort), do: items
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

  test "auctions page defaults to biddable tokens with directory language", %{
    conn: conn,
    human: human
  } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/auctions")

    assert html =~ "Use stablecoins to back agents with provable revenue."
    assert html =~ "Biddable"
    assert html =~ "Atlas"
    refute html =~ "Nova"
    assert html =~ "Auction clearing"
    assert html =~ "The short, non-crypto-heavy version."
    assert html =~ "Half of auction USDC goes to the Uniswap v4 pool"
  end

  test "mode toggle switches from biddable to live tokens", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/auctions")

    html =
      view
      |> form("form[phx-change='filters_changed']", %{
        "filters" => %{"mode" => "live", "sort" => "newest"}
      })
      |> render_change()

    assert html =~ "Nova"
    refute html =~ "Atlas"
    assert html =~ "Uniswap spot"
  end
end
