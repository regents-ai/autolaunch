defmodule AutolaunchWeb.ProfileLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule PortfolioStub do
    def get_snapshot(nil), do: {:error, :unauthorized}

    def get_snapshot(_human) do
      {:ok,
       %{
         status: "ready",
         launched_tokens: [
           %{
             agent_name: "Atlas",
             symbol: "ATLAS",
             phase: "biddable",
             current_price_usdc: "0.0050",
             implied_market_cap_usdc: "500000000",
             detail_url: "/subjects/0x" <> String.duplicate("1", 64)
           }
         ],
         staked_tokens: [
           %{
             agent_name: "Nova",
             symbol: "NOVA",
             phase: "live",
             staked_token_amount: "1200",
             staked_usdc_value: "13.2",
             claimable_usdc: "4.5",
             implied_market_cap_usdc: "1100000000",
             detail_url: "/subjects/0x" <> String.duplicate("2", 64)
           }
         ],
         refreshed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         next_manual_refresh_at: nil
       }}
    end

    def request_manual_refresh(_human) do
      {:ok,
       %{
         status: "running",
         launched_tokens: [],
         staked_tokens: [],
         refreshed_at: nil,
         next_manual_refresh_at:
           DateTime.add(DateTime.utc_now(), 30, :second) |> DateTime.to_iso8601()
       }}
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :profile_live, [])
    Application.put_env(:autolaunch, :profile_live, portfolio_module: PortfolioStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :profile_live, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:profile-live", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Operator"
      })

    %{human: human}
  end

  test "profile page shows launched and staked token tables", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/profile")

    assert html =~ "Tokens launched from your linked wallets."
    assert html =~ "Your active revenue positions."
    assert html =~ "Atlas"
    assert html =~ "Nova"
    assert html =~ "13.2 USDC"
    assert html =~ "Manage"
  end

  test "manual refresh starts cooldown state", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/profile")

    html =
      view
      |> element("button[phx-click='refresh_profile']")
      |> render_click()

    assert html =~ "Refresh in"
    assert html =~ "The snapshot is rebuilding in the background."
  end
end
