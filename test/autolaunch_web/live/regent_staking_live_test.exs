defmodule AutolaunchWeb.RegentStakingLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  defmodule StakingStub do
    def overview(_human) do
      {:ok,
       %{
         chain_id: 8453,
         chain_label: "Base",
         contract_address: "0x9999999999999999999999999999999999999999",
         owner_address: "0x1111111111111111111111111111111111111111",
         stake_token_address: "0x2222222222222222222222222222222222222222",
         usdc_address: "0x3333333333333333333333333333333333333333",
         treasury_recipient: "0x4444444444444444444444444444444444444444",
         staker_share_bps: 10_000,
         paused: false,
         total_staked: "12345",
         total_usdc_received: "500",
         direct_deposit_usdc: "500",
         treasury_residual_usdc: "50",
         materialized_outstanding: "10",
         available_reward_inventory: "200",
         total_claimed_so_far: "25",
         wallet_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         wallet_stake_balance: "12",
         wallet_token_balance: "90",
         wallet_claimable_usdc: "5",
         wallet_claimable_regent: "3",
         wallet_funded_claimable_regent: "2"
       }}
    end

    def stake(%{"amount" => "1.5"}, _human), do: tx("0xstake")
    def unstake(%{"amount" => "1.0"}, _human), do: tx("0xunstake")
    def claim_usdc(_attrs, _human), do: tx("0xclaimusdc")
    def claim_regent(_attrs, _human), do: tx("0xclaimregent")
    def claim_and_restake_regent(_attrs, _human), do: tx("0xrestake")

    def prepare_deposit_usdc(%{
          "amount" => "2.0",
          "source_tag" => "manual",
          "source_ref" => "regent-staking"
        }) do
      prepared_tx("0xdeposit")
    end

    def prepare_withdraw_treasury(%{"amount" => "1.0", "recipient" => ""}) do
      prepared_tx("0xwithdraw")
    end

    defp tx(data) do
      {:ok,
       %{
         tx_request: %{
           chain_id: 8453,
           to: "0x9999999999999999999999999999999999999999",
           value: "0x0",
           data: data
         }
       }}
    end

    defp prepared_tx(data) do
      {:ok,
       %{
         prepared: %{
           tx_request: %{
             chain_id: 8453,
             to: "0x9999999999999999999999999999999999999999",
             value: "0x0",
             data: data
           }
         }
       }}
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :regent_staking_live, [])
    Application.put_env(:autolaunch, :regent_staking_live, context_module: StakingStub)
    on_exit(fn -> Application.put_env(:autolaunch, :regent_staking_live, original) end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:regent-staking-live", %{
        "wallet_address" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "wallet_addresses" => ["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
        "display_name" => "Operator"
      })

    %{human: human}
  end

  test "renders the Regent staking page", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/regent-staking")

    assert html =~ "$REGENT staking"
    assert html =~ "Company rewards rail"
    assert html =~ "Total REGENT staked"
    assert html =~ "Funded REGENT rewards"
    assert html =~ "Prepare stake"
    assert html =~ "Prepare USDC claim"
    assert html =~ "Prepare REGENT claim"
    assert html =~ "Prepare USDC deposit"
    assert html =~ "Prepare treasury withdrawal"
  end

  test "prepares wallet actions", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/regent-staking")

    html =
      view
      |> form("form[phx-change='stake_changed']", %{"stake" => %{"amount" => "1.5"}})
      |> render_change()

    assert html =~ "Prepare stake"

    html =
      view
      |> element("#regent-stake")
      |> render_click()

    assert html =~ "Send stake transaction"
    assert html =~ "0xstake"

    html =
      view
      |> form("form[phx-change='deposit_changed']", %{
        "deposit" => %{
          "amount" => "2.0",
          "source_tag" => "manual",
          "source_ref" => "regent-staking"
        }
      })
      |> render_change()

    assert html =~ "Prepare USDC deposit"

    html =
      view
      |> element("#regent-deposit-usdc")
      |> render_click()

    assert html =~ "Send USDC deposit"
    assert html =~ "0xdeposit"
  end

  test "anonymous visitors cannot prepare treasury actions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/regent-staking")

    html =
      view
      |> form("form[phx-change='deposit_changed']", %{
        "deposit" => %{
          "amount" => "2.0",
          "source_tag" => "manual",
          "source_ref" => "regent-staking"
        }
      })
      |> render_change()

    assert html =~ "Prepare USDC deposit"

    html =
      view
      |> element("#regent-deposit-usdc")
      |> render_click()

    assert html =~ "Connect a wallet first."
    refute html =~ "Send USDC deposit"
    refute html =~ "0xdeposit"
  end
end
