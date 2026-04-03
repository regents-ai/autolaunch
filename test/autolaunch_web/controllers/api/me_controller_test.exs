defmodule AutolaunchWeb.Api.MeControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule PortfolioStub do
    def get_snapshot(_human) do
      {:ok,
       %{
         status: "ready",
         launched_tokens: [%{agent_name: "Atlas"}],
         staked_tokens: [%{agent_name: "Nova"}],
         refreshed_at: nil,
         next_manual_refresh_at: nil
       }}
    end

    def request_manual_refresh(_human) do
      {:error, {:cooldown, 12}}
    end
  end

  setup %{conn: conn} do
    original = Application.get_env(:autolaunch, :me_controller, [])
    Application.put_env(:autolaunch, :me_controller, portfolio_module: PortfolioStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :me_controller, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:me-controller", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Bidder"
      })

    %{conn: conn, human: human}
  end

  test "profile returns the cached snapshot", %{conn: conn, human: human} do
    conn =
      conn
      |> init_test_session(privy_user_id: human.privy_user_id)
      |> get("/api/me/profile")

    assert %{
             "ok" => true,
             "profile" => %{
               "status" => "ready",
               "launched_tokens" => [%{"agent_name" => "Atlas"}],
               "staked_tokens" => [%{"agent_name" => "Nova"}]
             }
           } = json_response(conn, 200)
  end

  test "refresh_profile enforces cooldown responses", %{conn: conn, human: human} do
    conn =
      conn
      |> init_test_session(privy_user_id: human.privy_user_id)
      |> post("/api/me/profile/refresh")

    assert %{"ok" => false, "error" => %{"code" => "profile_refresh_cooldown"}} =
             json_response(conn, 429)
  end
end
