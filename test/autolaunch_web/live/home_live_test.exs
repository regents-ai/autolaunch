defmodule AutolaunchWeb.HomeLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defmodule LaunchStub do
    def list_auctions(_filters, _human) do
      [
        %{
          id: "auction-1",
          agent_id: "8453:42",
          agent_name: "Atlas",
          symbol: "ATLAS",
          phase: "biddable",
          current_price_quote: "0.04",
          implied_market_cap_quote: "4000000",
          ends_at: "2026-04-13T12:00:00Z",
          trust: %{ens: %{connected: true, name: "atlas.eth"}, world: %{connected: true}},
          detail_url: "/auctions/auction-1",
          subject_url: "/subjects/subject-1"
        },
        %{
          id: "auction-2",
          agent_id: "8453:77",
          agent_name: "Beacon",
          symbol: "BECN",
          phase: "live",
          current_price_quote: "0.09",
          implied_market_cap_quote: "9000000",
          ends_at: "2026-04-09T12:00:00Z",
          trust: %{},
          detail_url: "/auctions/auction-2",
          subject_url: "/subjects/subject-2"
        }
      ]
    end
  end

  setup do
    previous_home = Application.get_env(:autolaunch, :home_live, [])
    Application.put_env(:autolaunch, :home_live, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :home_live, previous_home)
    end)

    :ok
  end

  test "home page renders the signed-in dashboard layout", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Launch and grow agent economies"
    assert has_element?(view, "h1", "Launch and grow agent economies")
    refute has_element?(view, ".al-home-dashboard-visual")
    refute has_element?(view, ".al-home-dashboard-orbit")
    assert html =~ "Go to Launch"
    assert html =~ "Explore auctions"
    assert html =~ "Market snapshot"
    assert html =~ "Featured auctions"
    assert html =~ "Launch path"
    assert html =~ "Read Litepaper"
    assert html =~ ~s(href="/litepaper")
    assert html =~ ~s(href="/litepaper.md")
    refute html =~ "Revenue lanes"
    refute html =~ "Trust status"
    refute html =~ "Latest activity"
    refute html =~ "al-home-network-panel"
    refute html =~ "al-shell-network-card"
    assert html =~ "al-shell-notification-button"
    refute html =~ "al-shell-notice-dot"
    assert html =~ "Community room"
    assert html =~ "Read the launch room."
    assert html =~ "0/200 seats"
    assert html =~ "autolaunch your agent ownership token"
    refute html =~ "Selected launch setup"
    refute html =~ "No launch setup selected"
    refute html =~ "Choose or create a launch setup to get started."
    refute html =~ "Select setup"
    refute html =~ "Pay with"
    refute html =~ "Estimated cost"
    refute html =~ "0.00 USDC"
    assert html =~ "Atlas"
    assert html =~ "Beacon"
    assert html =~ "$ATLAS"
    assert html =~ "$BECN"
    assert html =~ ~s(href="/launch")
  end

  test "home page keeps featured market and activity data aligned with live auctions", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, ".al-home-auction-row", "Atlas")
    assert has_element?(view, "article", "Atlas is the clearest next stop")
  end
end
