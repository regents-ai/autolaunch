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
          agent_id: "84532:42",
          agent_name: "Atlas",
          symbol: "ATLAS",
          network: "base-sepolia",
          chain: "Base Sepolia",
          phase: "biddable",
          price_source: "auction_clearing",
          current_price_usdc: "0.0050",
          implied_market_cap_usdc: "9.5E+2",
          total_bid_volume: "18240.75",
          minimum_raise_progress_percent: 72,
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
          id: "auc_beta",
          agent_id: "8453:7",
          agent_name: "Cinder",
          symbol: "CNDR",
          network: "base",
          chain: "Base",
          phase: "biddable",
          price_source: "auction_clearing",
          current_price_usdc: "0.0085",
          implied_market_cap_usdc: "1000",
          total_bid_volume: "9250.00",
          minimum_raise_progress_percent: 41,
          detail_url: "/auctions/auc_beta",
          subject_url: nil,
          uniswap_url: "https://example.com/cinder",
          started_at: DateTime.add(DateTime.utc_now(), -1_800, :second) |> DateTime.to_iso8601(),
          ends_at: DateTime.add(DateTime.utc_now(), 43_200, :second) |> DateTime.to_iso8601(),
          trust: %{
            ens: %{connected: false, name: nil},
            world: %{connected: true, launch_count: 1}
          }
        },
        %{
          id: "auc_live",
          agent_id: "84532:99",
          agent_name: "Nova",
          symbol: "NOVA",
          network: "base",
          chain: "Base",
          phase: "live",
          price_source: "uniswap_spot",
          current_price_usdc: "0.0110",
          implied_market_cap_usdc: "1100000000",
          total_bid_volume: "26000.50",
          minimum_raise_progress_percent: 100,
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

  defmodule LiveOnlyLaunchStub do
    def list_auctions(_filters, _human) do
      [
        %{
          id: "auc_live",
          agent_id: "84532:99",
          agent_name: "Nova",
          symbol: "NOVA",
          network: "base",
          chain: "Base",
          phase: "live",
          price_source: "uniswap_spot",
          current_price_usdc: "0.0110",
          implied_market_cap_usdc: "1100000000",
          total_bid_volume: "26000.50",
          minimum_raise_progress_percent: 100,
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
    end
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

  test "market page defaults to biddable tokens with dashboard layout", %{
    conn: conn,
    human: human
  } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/auctions")

    assert html =~ "Open markets"
    assert html =~ "Total market cap"
    assert html =~ "Total bid volume"
    assert html =~ "Featured market"
    assert html =~ "Top markets"
    assert html =~ "Atlas"
    assert html =~ "Cinder"
    refute html =~ "Nova"
    assert html =~ "Auction clearing"
    assert html =~ "Active auctions"
    assert html =~ "Search by name, symbol, agent ID, or ENS"
    assert html =~ "Open bid page"
    assert html =~ "Cinder"
    assert html =~ "$1,000"
  end

  test "mode toggle switches from biddable to live tokens", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/auctions")

    _html =
      view
      |> form("form[phx-change='filters_changed']", %{
        "filters" => %{"mode" => "live", "network" => "all", "search" => "", "sort" => "newest"}
      })
      |> render_change()

    assert has_element?(view, "#auction-row-auc_live")
    refute has_element?(view, "#auction-row-auc_active")
    refute has_element?(view, "#auction-row-auc_beta")
    assert render(view) =~ "Uniswap spot"
    assert render(view) =~ "Open token page"
  end

  test "search and network filters narrow the market list", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/auctions")

    _html =
      view
      |> form("form[phx-change='filters_changed']", %{
        "filters" => %{
          "mode" => "biddable",
          "network" => "base-sepolia",
          "search" => "atlas.eth",
          "sort" => "market_cap_desc"
        }
      })
      |> render_change()

    assert has_element?(view, "#auction-row-auc_active")
    refute has_element?(view, "#auction-row-auc_beta")
    refute has_element?(view, "#auction-row-auc_live")
    assert render(view) =~ "Base Sepolia"
    assert render(view) =~ "Atlas"
    refute render(view) =~ "Cinder</h2>"
  end

  test "featured market falls back to a live auction when no biddable auction exists", %{
    conn: conn,
    human: human
  } do
    original = Application.get_env(:autolaunch, :auctions_live, [])
    Application.put_env(:autolaunch, :auctions_live, launch_module: LiveOnlyLaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :auctions_live, original)
    end)

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/auctions")

    assert html =~ "Featured market"
    assert html =~ "Nova"
    assert html =~ "Open token page"
  end

  test "search with no matches clears the featured card instead of showing an unrelated market",
       %{
         conn: conn,
         human: human
       } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/auctions")

    _html =
      view
      |> form("form[phx-change='filters_changed']", %{
        "filters" => %{
          "mode" => "biddable",
          "network" => "all",
          "search" => "no-match-here",
          "sort" => "newest"
        }
      })
      |> render_change()

    assert render(view) =~ "No auctions match this view yet."
    refute render(view) =~ "Atlas</h2>"
  end
end
