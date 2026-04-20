defmodule AutolaunchWeb.HomeLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defmodule LaunchStub do
    def list_auctions(_filters, _human) do
      [
        %{
          id: "auction-1",
          agent_id: "84532:42",
          agent_name: "Atlas",
          symbol: "ATLAS",
          phase: "biddable",
          current_price_usdc: "0.04",
          implied_market_cap_usdc: "4000000",
          ends_at: "2026-04-13T12:00:00Z",
          trust: %{ens: %{connected: true, name: "atlas.eth"}, world: %{connected: true}},
          detail_url: "/auctions/auction-1",
          subject_url: "/subjects/subject-1"
        },
        %{
          id: "auction-2",
          agent_id: "84532:77",
          agent_name: "Beacon",
          symbol: "BECN",
          phase: "live",
          current_price_usdc: "0.09",
          implied_market_cap_usdc: "9000000",
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

  test "home page renders the new landing layout with market tables", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Start the launch, follow the sale, and return for what comes next."
    assert html =~ "Open auctions"
    assert html =~ "regent autolaunch prelaunch wizard"
    assert html =~ "Hermes"
    assert html =~ "OpenClaw"
    assert html =~ "IronClaw"
    assert html =~ "Codex"
    assert html =~ "Claude"
    assert html =~ "Open auctions"
    assert html =~ "Post-auction tokens"
    assert html =~ "Atlas"
    assert html =~ "Beacon"
    assert html =~ "Start with one launch path"
    assert html =~ "Bid with a budget and a price cap"
    assert html =~ "Come back after the auction"
    assert html =~ ~s(href="/auctions")
  end

  test "home page keeps the market table actions aligned with active and past tokens", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "a[href='/auctions/auction-1']", "Open bid view")
    assert has_element?(view, "a[href='/subjects/subject-2']", "Open token page")
  end
end
