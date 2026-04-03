defmodule Autolaunch.PortfolioTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Portfolio
  alias Autolaunch.Portfolio.Snapshot
  alias Autolaunch.Repo

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_auctions(_filters, _human) do
      [
        %{
          id: "auc_1",
          owner_address: "0x1111111111111111111111111111111111111111",
          agent_id: "11155111:42",
          agent_name: "Atlas",
          symbol: "ATLAS",
          phase: "biddable",
          current_price_usdc: "0.005",
          implied_market_cap_usdc: "500000000",
          detail_url: "/auctions/auc_1",
          subject_url: "/subjects/0x" <> String.duplicate("1", 64),
          subject_id: "0x" <> String.duplicate("1", 64)
        },
        %{
          id: "auc_2",
          owner_address: "0x2222222222222222222222222222222222222222",
          agent_id: "11155111:99",
          agent_name: "Nova",
          symbol: "NOVA",
          phase: "live",
          current_price_usdc: "0.011",
          implied_market_cap_usdc: "1100000000",
          detail_url: "/auctions/auc_2",
          subject_url: "/subjects/0x" <> String.duplicate("2", 64),
          subject_id: "0x" <> String.duplicate("2", 64)
        }
      ]
    end
  end

  defmodule RevenueStub do
    def subject_wallet_positions("0x" <> <<"1", _rest::binary>>, _wallets) do
      {:ok,
       %{
         wallet_stake_balance_raw: 0,
         wallet_stake_balance: "0",
         claimable_usdc_raw: 0,
         claimable_usdc: "0"
       }}
    end

    def subject_wallet_positions("0x" <> <<"2", _rest::binary>>, _wallets) do
      {:ok,
       %{
         wallet_stake_balance_raw: 1_200_000_000_000_000_000_000,
         wallet_stake_balance: "1200",
         claimable_usdc_raw: 4_500_000,
         claimable_usdc: "4.5"
       }}
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :portfolio, [])

    Application.put_env(
      :autolaunch,
      :portfolio,
      launch_module: LaunchStub,
      revenue_module: RevenueStub
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :portfolio, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:portfolio", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Operator"
      })

    %{human: human}
  end

  test "refresh_snapshot stores launched and staked rows", %{human: human} do
    assert {:ok, snapshot} = Portfolio.refresh_snapshot(human)

    assert snapshot.status == "ready"
    assert length(snapshot.launched_tokens_payload) == 1
    assert length(snapshot.staked_tokens_payload) == 1

    stored = Repo.get_by!(Snapshot, human_id: human.id)
    assert hd(stored.launched_tokens_payload)["agent_name"] == "Atlas"
    assert hd(stored.staked_tokens_payload)["staked_usdc_value"] == "13.2"
  end
end
