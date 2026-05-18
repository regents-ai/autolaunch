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
             current_price_quote: "0.0050",
             implied_market_cap_quote: "500000000",
             detail_url: "/subjects/0x" <> String.duplicate("1", 64)
           }
         ],
         staked_tokens: [
           %{
             agent_name: "Nova",
             symbol: "NOVA",
             phase: "live",
             staked_token_amount: "1200",
             staked_quote_value: "13.2",
             claimable_usdc: "4.5",
             implied_market_cap_quote: "1100000000",
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

  defmodule CooldownPortfolioStub do
    def get_snapshot(_human) do
      {:ok,
       %{
         status: "ready",
         launched_tokens: [],
         staked_tokens: [],
         refreshed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         next_manual_refresh_at:
           DateTime.add(DateTime.utc_now(), 30, :second) |> DateTime.to_iso8601()
       }}
    end

    def request_manual_refresh(_human) do
      send(Application.fetch_env!(:autolaunch, :profile_live_test_pid), :refresh_requested)
      {:ok, %{}}
    end
  end

  defmodule AgentsStub do
    def list_agents(_human) do
      [
        %{
          id: "8453:42",
          agent_id: "8453:42",
          name: "Atlas Agent",
          ens: nil,
          state: "eligible",
          access_mode: "owner",
          owner_address: "0x1111111111111111111111111111111111111111",
          agent_wallet: "0x1111111111111111111111111111111111111111"
        }
      ]
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :profile_live, [])
    original_test_pid = Application.get_env(:autolaunch, :profile_live_test_pid)

    Application.put_env(:autolaunch, :profile_live,
      portfolio_module: PortfolioStub,
      agents_module: AgentsStub
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :profile_live, original)

      if original_test_pid do
        Application.put_env(:autolaunch, :profile_live_test_pid, original_test_pid)
      else
        Application.delete_env(:autolaunch, :profile_live_test_pid)
      end
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:profile-live", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Operator"
      })

    %{human: human}
  end

  test "profile page shows launched and staked token summaries", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/profile")

    assert html =~ "Identity and trust"
    assert html =~ "Wallet overview"
    assert html =~ "Profile trust lives here now."
    assert html =~ "Connected agents"
    assert html =~ "Complete agent trust before launch."
    assert html =~ "Atlas Agent"
    assert html =~ "ENS name"
    assert html =~ "ERC-8004 + ENSIP-25"
    assert html =~ "World AgentBook"
    assert html =~ "Strongly recommended"
    assert html =~ "Linked identities"
    assert html =~ "Launch history"
    assert html =~ "Atlas"
    assert html =~ "Nova"
    assert html =~ "13.2 $REGENT"
    assert html =~ "Open token page"
    assert html =~ "Open positions"
  end

  test "manual refresh starts cooldown state", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/profile")

    html =
      view
      |> element("button[phx-click='refresh_profile']")
      |> render_click()

    assert html =~ "Refresh in"
    assert html =~ "Refreshing"
  end

  test "manual refresh does not run while the button is disabled", %{conn: conn, human: human} do
    Application.put_env(:autolaunch, :profile_live, portfolio_module: CooldownPortfolioStub)
    Application.put_env(:autolaunch, :profile_live_test_pid, self())

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, html} = live(conn, "/profile")

    assert html =~ "disabled"

    assert_raise ArgumentError, fn ->
      view
      |> element("button[phx-click='refresh_profile']")
      |> render_click()
    end

    refute_received :refresh_requested
  end
end
