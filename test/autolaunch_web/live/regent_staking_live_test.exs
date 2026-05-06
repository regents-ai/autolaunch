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
         revenue_share_supply_denominator: "100000000000",
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

    def stake(%{"amount" => "1.5", "receiver" => ""}, _human), do: tx("0xstake")

    def stake(
          %{"amount" => "1.5", "receiver" => "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
          _human
        ),
        do: tx("0xstakeforreceiver")

    def unstake(%{"amount" => "1.0"}, _human), do: tx("0xunstake")
    def claim_usdc(_attrs, _human), do: tx("0xclaimusdc")
    def claim_regent(_attrs, _human), do: tx("0xclaimregent")
    def claim_and_restake_regent(_attrs, _human), do: tx("0xrestake")

    defp tx(data) do
      {:ok,
       %{
         prepared: %{
           wallet_action: %{
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

    on_exit(fn ->
      Application.put_env(:autolaunch, :regent_staking_live, original)
    end)

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
    assert html =~ "Stake for split of protocol stables"
    assert html =~ "earn 20% bonus $REGENT in the first year"
    assert html =~ "Total REGENT staked"
    assert html =~ "Bonus $REGENT available"
    assert html =~ "It does not guarantee yield."
    assert html =~ "Prepare stake"
    assert html =~ "Prepare USDC claim"
    assert html =~ "Prepare REGENT claim"
    assert html =~ "Prepare unstake"
    refute html =~ "Prepare USDC deposit"
    refute html =~ "Prepare treasury withdrawal"
    refute html =~ "USDC deposit amount"
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
      |> element("#regent-claim-usdc")
      |> render_click()

    assert html =~ "Send USDC claim"
    assert html =~ "0xclaimusdc"

    html =
      view
      |> form("form[phx-change='unstake_changed']", %{"unstake" => %{"amount" => "1.0"}})
      |> render_change()

    assert html =~ "Prepare unstake"

    html =
      view
      |> element("#regent-unstake")
      |> render_click()

    assert html =~ "Send unstake transaction"
    assert html =~ "0xunstake"
  end

  test "prepares stake for another wallet", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/regent-staking")

    html =
      view
      |> form("form[phx-change='stake_changed']", %{
        "stake" => %{
          "amount" => "1.5",
          "stake_for_different_address" => "true"
        }
      })
      |> render_change()

    assert html =~ "Receiving wallet"

    html =
      view
      |> form("form[phx-change='stake_changed']", %{
        "stake" => %{
          "amount" => "1.5",
          "stake_for_different_address" => "true",
          "receiver" => "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
      })
      |> render_change()

    assert html =~ "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    html =
      view
      |> element("#regent-stake")
      |> render_click()

    assert html =~ "Send stake transaction"
    assert html =~ "0xstakeforreceiver"
  end

  test "anonymous visitors are sent to wallet connection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/regent-staking")

    assert has_element?(view, "#regent-stake-connect", "Connect wallet")
    assert has_element?(view, "#regent-claim-usdc-connect", "Connect wallet")
    assert has_element?(view, "#regent-unstake-connect", "Connect wallet")
    refute has_element?(view, "#regent-deposit-usdc")
    refute has_element?(view, "#regent-withdraw-treasury")
  end
end
